# Verified boot: signed-UKI install for any device whose bootloader chain
# enforces UEFI Secure Boot (docs/verified-boot.md).
#
#   vendor bootloader --> U-Boot --UEFI Secure Boot--> systemd-boot
#                                                      --> signed UKI
#                                                          (kernel+initrd
#                                                          +cmdline+dtb)
#
# The bootloader half of the chain -- anchoring a root of trust in the vendor
# bootloader and building a U-Boot that enforces Secure Boot against the db
# key -- is device-specific and happens outside NixOS (the Fairphone 5, the
# reference device for this, uses avb_custom_key + the
# fairphone-fp5-verified-boot tools; see its device module). This module is
# the device-agnostic UKI half: it replaces the stock systemd-boot install
# with one that builds a Unified Kernel Image per generation -- kernel,
# initrd, kernel command line and device tree in one PE -- and signs it plus
# systemd-boot with the db key from `pkiBundle`, at switch time, on the
# device. Keys never enter the Nix store; they live on the encrypted root,
# which is exactly the boundary this whole chain protects.
#
# Everything in the UKI is covered by its signature, so the ESP contents
# stop being trusted input: an edited command line, swapped initrd or stale
# kernel simply fails Secure Boot verification in U-Boot.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.vanilla-mobile.verifiedBoot;

  esp = config.boot.loader.efi.efiSysMountPoint;
  timeout = if config.boot.loader.timeout == null then 5 else config.boot.loader.timeout;

  # ukify, the systemd-boot binary and the UKI stub, from one systemd build.
  systemdBoot = pkgs.systemdUkify;
  efiArch = pkgs.stdenv.hostPlatform.efiArch;
  bootFileName = "BOOT${lib.toUpper efiArch}.EFI";

  embedDtb =
    cfg.embedDevicetree
    && config.hardware.deviceTree.enable
    && config.hardware.deviceTree.name != null;

  installHook = pkgs.writeShellApplication {
    name = "install-signed-uki";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.sbsigntool
    ];
    text = ''
      toplevel=$1
      esp=${esp}
      keys=${cfg.pkiBundle}
      limit=${toString cfg.configurationLimit}
      profiles=/nix/var/nix/profiles

      sdboot=${systemdBoot}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi
      stub=${systemdBoot}/lib/systemd/boot/efi/linux${efiArch}.efi.stub
      ukify=${systemdBoot}/lib/systemd/ukify

      if [ ! -r "$keys/db.key" ] || [ ! -r "$keys/db.crt" ]; then
        echo "verified-boot: $keys/db.key + db.crt not found." >&2
        echo "Generate them with 'uboot-efi-keys keygen' and copy both files" >&2
        echo "into $keys (root-only). See docs/verified-boot.md." >&2
        exit 1
      fi

      # Sign into place atomically: a crash mid-write must never leave a
      # half-written EFI binary where the firmware will look for it.
      sign() {
        sbsign --key "$keys/db.key" --cert "$keys/db.crt" --output "$2.tmp" "$1" 2>/dev/null
        mv "$2.tmp" "$2"
      }

      mkdir -p "$esp/EFI/BOOT" "$esp/EFI/systemd" "$esp/EFI/Linux" "$esp/loader"

      sign "$sdboot" "$esp/EFI/systemd/systemd-boot${efiArch}.efi"
      cp "$esp/EFI/systemd/systemd-boot${efiArch}.efi" "$esp/EFI/BOOT/${bootFileName}.tmp"
      mv "$esp/EFI/BOOT/${bootFileName}.tmp" "$esp/EFI/BOOT/${bootFileName}"

      # The newest $limit generations, numerically.
      gens=()
      for link in "$profiles"/system-*-link; do
        [ -e "$link" ] || continue
        n=''${link##*/system-}
        n=''${n%-link}
        gens+=("$n")
      done
      mapfile -t gens < <(printf '%s\n' "''${gens[@]}" | sort -n | tail -n "$limit")
      if [ "''${#gens[@]}" -eq 0 ]; then
        echo "verified-boot: no system generations under $profiles" >&2
        exit 1
      fi

      # UKIs are rebuilt only when a generation's toplevel changed; the
      # manifest remembers what each installed UKI was built from.
      manifest=$esp/loader/uki-manifest
      declare -A known
      if [ -f "$manifest" ]; then
        while read -r g t; do known[$g]=$t; done < "$manifest"
      fi

      default_file=""
      : > "$manifest.tmp"
      for gen in "''${gens[@]}"; do
        link=$profiles/system-$gen-link
        gtop=$(readlink -f "$link")
        spec=$link/boot.json
        out=$esp/EFI/Linux/nixos-generation-$gen.efi

        if [ ! -r "$spec" ]; then
          echo "verified-boot: generation $gen has no bootspec; skipped (not bootable)" >&2
          continue
        fi
        if [ -n "$(jq -r '."org.nixos.bootspec.v1".initrdSecrets // empty' "$spec")" ]; then
          echo "verified-boot: generation $gen uses initrd secrets, which cannot" >&2
          echo "be appended to a signed UKI; this setup does not support them." >&2
          exit 1
        fi

        if [ "''${known[$gen]:-}" != "$gtop" ] || [ ! -f "$out" ]; then
          kernel=$(jq -r '."org.nixos.bootspec.v1".kernel' "$spec")
          initrd=$(jq -r '."org.nixos.bootspec.v1".initrd' "$spec")
          init=$(jq -r '."org.nixos.bootspec.v1".init' "$spec")
          params=$(jq -r '."org.nixos.bootspec.v1".kernelParams | join(" ")' "$spec")
          dtb=$(jq -r '."org.vanilla-mobile.verified-boot".devicetree // empty' "$spec")

          uki=$(mktemp --tmpdir uki-XXXXXX.efi)
          args=(build
            --linux "$kernel"
            --initrd "$initrd"
            --cmdline "init=$init $params"
            --stub "$stub"
            --output "$uki")
          [ -n "$dtb" ] && args+=(--devicetree "$dtb")
          "$ukify" "''${args[@]}" > /dev/null
          sign "$uki" "$out"
          rm -f "$uki"
          echo "verified-boot: signed generation $gen"
        fi

        printf '%s %s\n' "$gen" "$gtop" >> "$manifest.tmp"
        if [ "$gtop" = "$(readlink -f "$toplevel")" ]; then
          default_file=nixos-generation-$gen.efi
        fi
      done
      mv "$manifest.tmp" "$manifest"

      # Drop UKIs that fell out of the window.
      for f in "$esp"/EFI/Linux/nixos-generation-*.efi; do
        [ -e "$f" ] || continue
        keep=0
        for gen in "''${gens[@]}"; do
          [ "$f" = "$esp/EFI/Linux/nixos-generation-$gen.efi" ] && keep=1
        done
        [ "$keep" = 1 ] || rm -f "$f"
      done

      # A previous plain systemd-boot install leaves type-1 entries in
      # loader/entries and their kernels under EFI/nixos. They fail
      # verification once U-Boot enforces Secure Boot, so they are cleaned up
      # eventually -- but only once a signed UKI has actually booted, kept as
      # a fallback boot path until then (they are the only way back if the
      # first UKI does not boot). The stamp records that a UKI came up.
      booted_uki_stamp=$esp/loader/.verified-boot-uki-confirmed
      if [ -e "$booted_uki_stamp" ]; then
        rm -f "$esp"/loader/entries/nixos*.conf
        rm -rf "$esp"/EFI/nixos
      else
        echo "verified-boot: keeping the existing systemd-boot entries as a" \
          "fallback until a signed UKI is confirmed booted (see docs)"
      fi

      [ -n "$default_file" ] || default_file=nixos-generation-''${gens[-1]}.efi
      {
        echo "timeout ${toString timeout}"
        echo "default $default_file"
        echo "editor no"
      } > "$esp/loader/loader.conf.tmp"
      mv "$esp/loader/loader.conf.tmp" "$esp/loader/loader.conf"
      sync
    '';
  };
in {
  options.vanilla-mobile.verifiedBoot = {
    enable = lib.mkEnableOption "signed-UKI boot for the verified chain (docs/verified-boot.md)";

    pkiBundle = lib.mkOption {
      type = lib.types.str;
      default = "/etc/verified-boot";
      description = ''
        On-device directory holding `db.key` and `db.crt` (from
        `uboot-efi-keys keygen`), used to sign systemd-boot and each
        generation's UKI at switch time. Keep it root-owned, mode 0700; it
        lives on the encrypted root, never in the Nix store.
      '';
    };

    configurationLimit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = ''
        How many generations get a signed UKI on the ESP. UKIs carry the
        whole kernel + initrd, so each one costs ~30-40 MB of ESP space.
      '';
    };

    embedDevicetree = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Embed the kernel's own device tree in each UKI (applied through
        U-Boot's EFI_DT_FIXUP protocol), so the DTB is covered by the
        signature and always matches the kernel. Disable only if a UKI boot
        fails to bring up the panel, which would mean falling back to the
        DTB U-Boot provides.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.external = {
      enable = true;
      installHook = lib.getExe installHook;
    };

    # Per-generation DTB, carried in the bootspec so old generations keep
    # the device tree that matches *their* kernel, not the current one.
    # (Bootspec itself is always generated on current nixpkgs.)
    boot.bootspec.extensions."org.vanilla-mobile.verified-boot" = lib.mkIf embedDtb {
      devicetree = "${config.hardware.deviceTree.package}/${config.hardware.deviceTree.name}";
    };

    # UKI signing tool on the device itself. Device-specific bootloader
    # tooling (e.g. the FP5's AVB boot-image signing) is added by the device
    # module, not here.
    environment.systemPackages = [
      pkgs.sbsigntool
    ];

    # Records that the system actually came up through a signed UKI, which is
    # what lets the next switch retire the old systemd-boot entries kept as a
    # fallback. systemd-boot writes LoaderEntrySelected to an EFI variable
    # naming the entry it booted; if that is one of our UKIs, stamp the ESP.
    systemd.services.verified-boot-confirm-uki = {
      description = "Stamp the ESP once a signed UKI has booted";
      wantedBy = [ "multi-user.target" ];
      # The stamp is written to the ESP, so the ESP must be mounted first --
      # ordering on local-fs.target alone let this run during very early boot
      # (before /boot mounted and before the RTC offset applied), so the write
      # was lost. RequiresMountsFor pins it after the actual ESP mount.
      after = [ "local-fs.target" ];
      unitConfig.RequiresMountsFor = esp;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        var=/sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
        stamp=${esp}/loader/.verified-boot-uki-confirmed
        [ -e "$stamp" ] && exit 0
        # The value is UTF-16; strip the 4-byte efivar attribute prefix and
        # nulls to read it as text.
        if [ -r "$var" ] \
          && ${pkgs.coreutils}/bin/tail -c +5 "$var" \
             | ${pkgs.coreutils}/bin/tr -d '\0' \
             | ${pkgs.gnugrep}/bin/grep -q 'nixos-generation-.*\.efi'; then
          : > "$stamp"
          echo "verified-boot: confirmed boot via signed UKI; legacy entries" \
            "will be retired on the next switch"
        fi
      '';
    };
  };
}
