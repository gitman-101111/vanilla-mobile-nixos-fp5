# Generates UEFI Secure Boot certificates and packs them into the U-Boot EFI
# variable store ("seed") that mkFairphoneFp5SecureBootImage embeds. The seed
# holds only public certificates; the private keys stay wherever the user
# generated them (the db key must reach the phone's pkiBundle so generations
# can be signed at switch time).
#
# efivar.py is U-Boot's own store tool, taken from the same pinned source the
# bootloader is built from rather than copied here.
{
  lib,
  writeShellApplication,
  openssl,
  efitools,
  util-linux,
  python3,
  ubootSrc,
}:
writeShellApplication {
  name = "uboot-efi-keys";

  runtimeInputs = [
    openssl
    efitools
    util-linux
    (python3.withPackages (ps: [ ps.pyopenssl ]))
  ];

  text = ''
    efivar=${ubootSrc}/tools/efivar.py

    usage() {
      cat <<'EOF'
    uboot-efi-keys - UEFI Secure Boot keys and U-Boot variable-store seed

    Usage:
      uboot-efi-keys keygen <dir>
          Generate PK, KEK and db RSA-2048 certificate pairs (X.key + X.crt)
          plus an owner GUID. db.key is what signs bootloaders and UKIs;
          it must end up in the phone's pkiBundle directory. Keep every .key
          secret.

      uboot-efi-keys seed --keys <dir> --out <ubootefi.var>
          Build the EFI variable store holding PK/KEK/db from <dir>'s
          certificates. The output contains public material only and is what
          mkFairphoneFp5SecureBootImage embeds into U-Boot.
    EOF
      exit "''${1:-0}"
    }

    [ "$#" -ge 1 ] || usage 1
    cmd=$1
    shift

    keys="" out=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --keys) keys=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        -h | --help) usage 0 ;;
        *)
          if [ "$cmd" = keygen ] && [ -z "$keys" ]; then
            keys=$1
            shift
          else
            echo "unknown argument: $1" >&2
            usage 1
          fi
          ;;
      esac
    done

    case "$cmd" in
      keygen)
        [ -n "$keys" ] || usage 1
        mkdir -p "$keys"
        uuidgen > "$keys/owner-guid"
        for name in PK KEK db; do
          (
            umask 077
            openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 7300 \
              -subj "/CN=NixOS verified boot $name/" \
              -keyout "$keys/$name.key" -out "$keys/$name.crt" 2>/dev/null
          )
        done
        echo "Wrote to $keys:"
        echo "  PK.key/.crt KEK.key/.crt  platform + key-exchange keys (keep offline)"
        echo "  db.key/.crt               signs U-Boot payloads; copy BOTH to the"
        echo "                            phone's pkiBundle (default /etc/verified-boot)"
        echo "  owner-guid                signature owner id used in the store"
        ;;

      seed)
        [ -n "$keys" ] && [ -n "$out" ] || usage 1
        guid=$(cat "$keys/owner-guid")
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        for name in PK KEK db; do
          cert-to-efi-sig-list -g "$guid" "$keys/$name.crt" "$tmp/$name.esl"
        done
        rm -f "$out"
        # efivar.py recognises PK/KEK/db by name and applies the right GUID
        # and authenticated-variable attributes itself.
        for name in PK KEK db; do
          python3 "$efivar" set -i "$out" -n "$name" -t file -d "$tmp/$name.esl"
        done
        echo "Variable store written to $out. Contents:"
        python3 "$efivar" print -i "$out" | grep -E "^(PK|KEK|db):" || true
        echo
        echo "Build the enforcing U-Boot image with"
        echo "  fairphone-fp5-verified-boot.mkSecureBootImage { efiVarSeed = $out; }"
        echo "(see docs/verified-boot.md), then sign that image with avb-boot-sign."
        ;;

      *)
        usage 1
        ;;
    esac
  '';

  meta = {
    description = "Generate UEFI Secure Boot keys and the U-Boot variable-store seed that enforces them";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "uboot-efi-keys";
  };
}
