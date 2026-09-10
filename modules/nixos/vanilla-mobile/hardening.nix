# Security hardening for a mobile handset.
#
# The measures a stock Linux stack can carry on this platform:
#
#   - Kernel/userspace attack-surface reduction: hardening sysctls and
#     kernel command-line flags available in mainline.
#   - hardened_malloc: the hardened_malloc allocator, system-wide (opt-in).
#   - Auto-reboot: reboot after N hours locked so data returns to rest
#     (LUKS locked, fingerprint unusable) -- the before-first-unlock analog.
#   - Per-connection Wi-Fi MAC randomization and Bluetooth RPA privacy.
#
# Structural limits remain: NixOS has no per-app sandbox or permission model,
# and there is no hardware attestation. Those gaps are documented in
# docs/hardening.md; treat this module as hardening, not a guarantee of
# equivalence to a locked-down Android handset.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.vanilla-mobile.hardening;


  autoRebootLimit = cfg.autoReboot.hours * 3600;

  autoRebootCheck = pkgs.writeShellScript "locked-auto-reboot" ''
    set -eu

    STATE=/run/locked-auto-reboot.since
    LIMIT=${toString autoRebootLimit}

    # "In use" is broader than the USB gate's "unlocked": a seatless (SSH)
    # session also counts, so maintenance over the network is never cut off
    # by a reboot.
    in_use=0
    while read -r id _; do
      [ -n "$id" ] || continue
      [ "$(loginctl show-session "$id" --property Class --value 2>/dev/null)" = "user" ] || continue
      if [ -z "$(loginctl show-session "$id" --property Seat --value 2>/dev/null)" ]; then
        in_use=1
        break
      fi
      if [ "$(loginctl show-session "$id" --property Active --value 2>/dev/null)" = "yes" ] \
        && [ "$(loginctl show-session "$id" --property LockedHint --value 2>/dev/null)" = "no" ]; then
        in_use=1
        break
      fi
    done <<EOF
    $(loginctl list-sessions --no-legend 2>/dev/null)
    EOF

    if [ "$in_use" = 1 ]; then
      rm -f "$STATE"
      exit 0
    fi

    now=$(date +%s)
    if [ -e "$STATE" ]; then
      since=$(cat "$STATE")
    else
      since=$now
      echo "$now" > "$STATE"
    fi

    remaining=$((LIMIT - (now - since)))
    if [ "$remaining" -le 0 ]; then
      echo "locked for ${toString cfg.autoReboot.hours}h; rebooting to put data back at rest"
      exec systemctl reboot
    fi

    # Arm the RTC so the deadline holds even if the device suspends: the
    # monotonic timer does not advance in sleep, but this alarm wakes the
    # system in time for the check that reboots it.
    rtcwake -m no -s "$remaining" >/dev/null 2>&1 || true
  '';
in
{
  options.vanilla-mobile.hardening = {
    enable = lib.mkEnableOption "security hardening defaults";

    kernel.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        The kernel-hardening subset that exists in mainline: restricted
        dmesg/kptr/perf/bpf/io_uring/userfaultfd, ptrace scoping, zero-on-
        alloc-and-free and freelist hardening on the command line, kexec
        disabled, and legacy protocol modules blacklisted. Every sysctl is
        set at override priority 900, so any single one can be overridden
        by a plain assignment in a host config.
      '';
    };

    memoryAllocator.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Use the hardened_malloc allocator system-wide
        (`environment.memoryAllocator.provider = "graphene-hardened"`).
        Off by default: it is a real mitigation but costs memory and
        performance, and some software misbehaves under it.
      '';
    };

    autoReboot = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Auto-reboot: if the device stays locked (and no SSH session is
          open) for `hours`, reboot it so the LUKS root returns to rest and
          the phone waits at the passphrase prompt. An RTC alarm is armed so
          the deadline holds through suspend.
        '';
      };

      hours = lib.mkOption {
        type = lib.types.ints.positive;
        default = 18;
        description = "Hours of continuous lock before the reboot.";
      };
    };

    macRandomization = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Randomize the Wi-Fi MAC for scans and connections via NetworkManager.";
      };

      mode = lib.mkOption {
        type = lib.types.enum [
          "random"
          "stable"
          "stable-ssid"
        ];
        default = "random";
        description = ''
          `random` (a new MAC per connection), `stable-ssid` (a stable MAC
          per network; needs NetworkManager >= 1.42) or `stable` (one hashed
          MAC).
        '';
      };
    };

    bluetoothPrivacy.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use resolvable private addresses for Bluetooth instead of the fixed hardware address.";
    };

    networkPrivacy.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Network privacy hygiene: IPv6 privacy (temporary) addresses, DNS over
        TLS, and NetworkManager's home-phoning connectivity check disabled.
      '';
    };

    faillock.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Rate-limit failed logins with pam_faillock: back off, then lock the
        account for a while after repeated failures. The LUKS passphrase at
        boot is unaffected -- this is the session/login gate.
      '';
    };

    usbguard.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        USBGuard device allowlisting for devices attached to a USB *host*:
        even while unlocked, only devices matching the policy attach. Only
        meaningful on a device used in USB-host/OTG mode (a peripheral-mode
        phone has no host bus for it to govern). Off by default because it
        needs a policy generated from the peripherals you actually use
        (`usbguard generate-policy`); an empty policy blocks everything.
      '';
    };

    duress = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Duress passphrase: a second LUKS passphrase entered at the initrd
          prompt that, instead of unlocking, destroys the LUKS keyslots
          (rendering the data unrecoverable) and powers off.

          OFF by default and intended to be enabled only after deliberate
          testing: a mistake here can wipe your own data. Enroll the duress
          passphrase into its own keyslot first (see docs/hardening.md), and
          keep the real root backed up.
        '';
      };

      keyslot = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 7;
        description = ''
          The LUKS keyslot holding the duress passphrase. When this slot (and
          only this slot) validates the entered passphrase, the wipe fires.
          Enroll it with `cryptsetup luksAddKey --key-slot <n>`.
        '';
      };

      device = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/dev/disk/by-partlabel/userdata";
        description = "The LUKS block device the duress passphrase guards.";
      };

      mapperName = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = ''
          The device-mapper name the initrd opens the LUKS root as (must match
          the name in `boot.initrd.luks.devices` / disko). The duress service
          opens this itself so the normal systemd-cryptsetup unit finds it
          already active.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Kernel attack surface and exploit mitigations.
      (lib.mkIf cfg.kernel.enable {
        # Disables kexec and hibernation (these devices have no swap to
        # resume from anyway), so the running kernel cannot be swapped out.
        security.protectKernelImage = lib.mkDefault true;

        # The boot menu editor lets anyone holding the phone add
        # init=/bin/sh to the kernel command line.
        boot.loader.systemd-boot.editor = lib.mkDefault false;

        boot.kernelParams = [
          # Zero memory at allocation and free time.
          "init_on_alloc=1"
          "init_on_free=1"
          # Keep slab caches apart so a bug in one object type cannot be
          # groomed through another's cache.
          "slab_nomerge"
          # Randomize page allocator freelists.
          "page_alloc.shuffle=1"
          # Randomize the kernel stack offset per syscall.
          "randomize_kstack_offset=on"
          # Synchronous IOMMU TLB invalidation (the arm64 default; pinned
          # here so nothing relaxes it).
          "iommu.strict=1"
        ];

        # 900 sits between nixpkgs's own mkDefault sysctls (1000) and a plain
        # assignment (100), so any one of these can be overridden from a host
        # config without mkForce.
        boot.kernel.sysctl = lib.mapAttrs (_: lib.mkOverride 900) {
          # Hide kernel logs and pointers from unprivileged users.
          "kernel.dmesg_restrict" = 1;
          "kernel.kptr_restrict" = 2;
          # perf, unprivileged eBPF and io_uring are steady sources of
          # kernel CVEs; keep all three away from apps.
          "kernel.perf_event_paranoid" = 3;
          "kernel.unprivileged_bpf_disabled" = 1;
          "net.core.bpf_jit_harden" = 2;
          "kernel.io_uring_disabled" = 2;
          # Only a parent may ptrace its children.
          "kernel.yama.ptrace_scope" = 1;
          # No line disciplines or userfaultfd for unprivileged users.
          "dev.tty.ldisc_autoload" = 0;
          "vm.unprivileged_userfaultfd" = 0;
          # No setuid core dumps; no writes through hostile fifos/regulars
          # in sticky directories.
          "fs.suid_dumpable" = 0;
          "fs.protected_fifos" = 2;
          "fs.protected_regular" = 2;
          # Routing-based attacks a phone on hostile networks should shrug
          # off.
          "net.ipv4.conf.all.accept_redirects" = 0;
          "net.ipv4.conf.default.accept_redirects" = 0;
          "net.ipv4.conf.all.secure_redirects" = 0;
          "net.ipv4.conf.default.secure_redirects" = 0;
          "net.ipv4.conf.all.send_redirects" = 0;
          "net.ipv4.conf.default.send_redirects" = 0;
          "net.ipv4.conf.all.accept_source_route" = 0;
          "net.ipv4.conf.default.accept_source_route" = 0;
          "net.ipv6.conf.all.accept_redirects" = 0;
          "net.ipv6.conf.default.accept_redirects" = 0;
          "net.ipv6.conf.all.accept_source_route" = 0;
          "net.ipv4.tcp_syncookies" = 1;
          "net.ipv4.tcp_rfc1337" = 1;
        };

        # Legacy protocols nothing on a phone speaks; keep them from ever
        # auto-loading.
        boot.blacklistedKernelModules = [
          "ax25"
          "netrom"
          "rose"
          "dccp"
          "sctp"
          "rds"
          "tipc"
          "n-hdlc"
          "af_802154"
          "appletalk"
          "atm"
        ];
      })

      # The hardened_malloc allocator, system-wide.
      (lib.mkIf cfg.memoryAllocator.enable {
        environment.memoryAllocator.provider = "graphene-hardened";
      })

      # Auto-reboot when left locked.
      (lib.mkIf cfg.autoReboot.enable {
        systemd.services.locked-auto-reboot = {
          description = "Reboot after ${toString cfg.autoReboot.hours}h locked, returning data to rest";
          path = [
            pkgs.coreutils
            pkgs.systemd
            pkgs.util-linux
          ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = autoRebootCheck;
            NoNewPrivileges = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            ProtectHome = true;
          };
        };

        systemd.timers.locked-auto-reboot = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "10min";
            OnUnitActiveSec = "10min";
            # A realtime spec too, so a device that just resumed re-checks
            # promptly instead of waiting out the monotonic remainder.
            OnCalendar = "*:00/10";
          };
        };
      })

      # Per-connection MAC randomization.
      (lib.mkIf cfg.macRandomization.enable {
        networking.networkmanager.wifi = {
          scanRandMacAddress = lib.mkDefault true;
          macAddress = lib.mkDefault cfg.macRandomization.mode;
        };
      })

      # Bluetooth resolvable private addresses.
      (lib.mkIf cfg.bluetoothPrivacy.enable {
        hardware.bluetooth.settings.General.Privacy = lib.mkDefault "device";
      })

      # Lockdown LSM: the kernel compiles it in and forces confidentiality
      # (see the FP5 kernel structuredExtraConfig), but the LSM only
      # initialises if the lsm= command line lists it. mkAfter so this wins
      # over the base lsm= that nixpkgs emits.
      (lib.mkIf cfg.kernel.enable {
        boot.kernelParams = lib.mkAfter [ "lsm=landlock,lockdown,yama,bpf" ];
      })

      # Network privacy hygiene.
      (lib.mkIf cfg.networkPrivacy.enable {
        # IPv6 temporary (privacy) addresses so outbound v6 traffic is not
        # tied to a stable interface identifier.
        networking.tempAddresses = lib.mkDefault "enabled";
        networking.networkmanager.settings.connectivity.enabled = lib.mkDefault false;

        # DNS over TLS via systemd-resolved (opportunistic so captive portals
        # and non-DoT resolvers still work).
        services.resolved = {
          enable = lib.mkDefault true;
          settings.Resolve.DNSOverTLS = lib.mkDefault "opportunistic";
        };
      })

      # Login throttling. `logFailures` is what wires pam_faillock into a
      # service's auth stack in nixpkgs; faillock.conf tunes it: 5 failures →
      # 15 min lockout, tracked per user. The LUKS passphrase at the initrd is
      # a separate gate and is unaffected.
      (lib.mkIf cfg.faillock.enable {
        security.pam.services = lib.genAttrs [ "login" "gdm-password" "sudo" ] (_: {
          logFailures = true;
        });
        environment.etc."security/faillock.conf".text = ''
          deny = 5
          fail_interval = 900
          unlock_time = 900
        '';
      })

      # USBGuard device allowlist for host-attached USB peripherals (only
      # meaningful in USB-host/OTG mode; a peripheral-mode phone has no host
      # bus to govern).
      (lib.mkIf cfg.usbguard.enable {
        services.usbguard = {
          enable = true;
          # Devices already connected at boot are allowed (so the device does
          # not lock out its own hubs); new ones must match the policy.
          presentDevicePolicy = lib.mkDefault "allow";
          implicitPolicyTarget = lib.mkDefault "block";
        };
      })

      # Duress passphrase (destroy-on-entry). systemd-initrd runs a small
      # service before cryptsetup that checks the entered passphrase against
      # ONLY the duress keyslot; a match wipes every keyslot and powers off.
      (lib.mkIf cfg.duress.enable {
        assertions = [
          {
            assertion = cfg.duress.device != null;
            message = "vanilla-mobile.hardening.duress.enable requires duress.device.";
          }
        ];
        # This service OWNS the root unlock prompt: it runs before the normal
        # systemd-cryptsetup unit, prompts once via systemd-ask-password (so
        # the unl0kr agent still renders it), and then either
        #   - the passphrase matches ONLY the duress keyslot -> luksErase
        #     destroys every keyslot (data unrecoverable) and the phone powers
        #     off; or
        #   - it opens the LUKS device itself, which leaves the mapper active
        #     so the subsequent systemd-cryptsetup@<name> unit finds it done;
        #     a wrong passphrase just re-prompts.
        # The detect (--test-passphrase --key-slot) and wipe (luksErase) are
        # validated on a loopback LUKS; the initrd integration below still
        # needs an on-device test, which is destructive by nature -- do it on
        # a throwaway/backed-up device. Off by default.
        boot.initrd.systemd.services.duress-check = {
          description = "Duress-aware LUKS unlock (wipe on duress passphrase)";
          wantedBy = [ "cryptsetup.target" ];
          before = [
            "cryptsetup.target"
            "systemd-cryptsetup@${cfg.duress.mapperName}.service"
          ];
          # Needs the ask-password agents and the backing device present.
          after = [ "systemd-ask-password-console.path" ];
          wants = [ "systemd-ask-password-console.path" ];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            dev=${lib.escapeShellArg cfg.duress.device}
            name=${lib.escapeShellArg cfg.duress.mapperName}
            slot=${toString cfg.duress.keyslot}

            # Already open (e.g. re-run)? Nothing to do.
            [ -e "/dev/mapper/$name" ] && exit 0

            while :; do
              pass=$(systemd-ask-password --timeout=0 \
                --id="duress:$dev" "Enter passphrase for $name:") || exit 1
              [ -n "$pass" ] || continue

              # Duress passphrase: matches the duress slot and ONLY it.
              if printf '%s' "$pass" | cryptsetup open --test-passphrase \
                   --key-slot "$slot" "$dev" >/dev/null 2>&1; then
                cryptsetup luksErase --batch-mode "$dev" >/dev/null 2>&1 || true
                systemctl poweroff --force --force
                exit 0
              fi

              # Real passphrase: open the mapper and let boot continue.
              if printf '%s' "$pass" | cryptsetup open "$dev" "$name" >/dev/null 2>&1; then
                exit 0
              fi
              # Wrong passphrase -> loop and re-prompt.
            done
          '';
        };
      })
    ]
  );
}
