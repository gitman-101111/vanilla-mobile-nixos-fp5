# Signs a U-Boot Android boot image for Android Verified Boot with the user's
# own key, producing what `fastboot flash boot` / `flash vbmeta` need for a
# device relocked on a custom root of trust (`avb_custom_key`). The private
# key never enters the store: this is a tool the user runs, not a derivation
# that signs.
{
  lib,
  writeShellApplication,
  android-tools, # provides avbtool
  openssl,
}:
writeShellApplication {
  name = "avb-boot-sign";

  runtimeInputs = [
    android-tools
    openssl
  ];

  text = ''
    # Fairphone 5 boot partition (BOARD_BOOTIMAGE_PARTITION_SIZE, 96 MiB).
    # Confirm on the device with `fastboot getvar partition-size:boot_a`.
    default_partition_size=100663296

    usage() {
      cat <<'EOF'
    avb-boot-sign - sign a boot image for a custom AVB root of trust

    Usage:
      avb-boot-sign keygen <dir>
          Generate an RSA-4096 AVB signing key (avb.pem, keep it secret) and
          the public-key blob to flash to avb_custom_key (avb_pkmd.bin).

      avb-boot-sign sign --key <avb.pem> --image <u-boot.img> --out <dir>
                         [--partition-size <bytes>] [--rollback-index <n>]
          Produce <dir>/boot.img (the input image with an AVB hash footer)
          and <dir>/vbmeta.img (signed vbmeta describing it), then verify
          both against the key. Defaults: partition-size 100663296 (the
          Fairphone 5 boot partition), rollback-index 0.

      avb-boot-sign verify --key <avb.pem> --dir <dir>
          Re-run the signature check on a previously produced <dir>.

      avb-boot-sign info --image <img>
          Dump the AVB structures of an image (avbtool info_image).
    EOF
      exit "''${1:-0}"
    }

    [ "$#" -ge 1 ] || usage 1
    cmd=$1
    shift

    key="" image="" out="" dir=""
    partition_size=$default_partition_size
    rollback_index=0

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --key) key=$2; shift 2 ;;
        --image) image=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --dir) dir=$2; shift 2 ;;
        --partition-size) partition_size=$2; shift 2 ;;
        --rollback-index) rollback_index=$2; shift 2 ;;
        -h | --help) usage 0 ;;
        *)
          # keygen takes a bare directory argument.
          if [ "$cmd" = keygen ] && [ -z "$out" ]; then
            out=$1
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
        [ -n "$out" ] || usage 1
        mkdir -p "$out"
        (
          umask 077
          openssl genrsa -out "$out/avb.pem" 4096 2>/dev/null
        )
        avbtool extract_public_key --key "$out/avb.pem" --output "$out/avb_pkmd.bin"
        echo "Wrote:"
        echo "  $out/avb.pem       private signing key - KEEP SECRET, back it up"
        echo "  $out/avb_pkmd.bin  public key, for: fastboot flash avb_custom_key"
        ;;

      sign)
        [ -n "$key" ] && [ -n "$image" ] && [ -n "$out" ] || usage 1
        mkdir -p "$out"
        # The image must be smaller than the partition minus the footer AVB
        # reserves; avbtool checks this and pads the image to partition size.
        cp --no-preserve=mode "$image" "$out/boot.img"
        avbtool add_hash_footer \
          --image "$out/boot.img" \
          --partition_name boot \
          --partition_size "$partition_size" \
          --algorithm SHA256_RSA4096 \
          --key "$key" \
          --rollback_index "$rollback_index"
        avbtool make_vbmeta_image \
          --key "$key" \
          --algorithm SHA256_RSA4096 \
          --include_descriptors_from_image "$out/boot.img" \
          --rollback_index "$rollback_index" \
          --padding_size 4096 \
          --output "$out/vbmeta.img"
        # verify_image on the vbmeta follows its hash descriptor to boot.img
        # in the same directory, so this checks the whole arrangement.
        avbtool verify_image --image "$out/vbmeta.img" --key "$key"
        echo
        echo "Signed. To flash (both slots; device unlocked, in fastboot):"
        echo "  fastboot flash boot_a $out/boot.img"
        echo "  fastboot flash boot_b $out/boot.img"
        echo "  fastboot flash vbmeta_a $out/vbmeta.img"
        echo "  fastboot flash vbmeta_b $out/vbmeta.img"
        echo
        echo "Do NOT run 'fastboot flashing lock' before working through"
        echo "docs/verified-boot.md - the order of checks there is what"
        echo "keeps a mistake recoverable."
        ;;

      verify)
        [ -n "$key" ] && [ -n "$dir" ] || usage 1
        avbtool verify_image --image "$dir/vbmeta.img" --key "$key"
        ;;

      info)
        [ -n "$image" ] || usage 1
        avbtool info_image --image "$image"
        ;;

      *)
        usage 1
        ;;
    esac
  '';

  meta = {
    description = "Sign a U-Boot boot image and vbmeta for a custom AVB root of trust (avb_custom_key)";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "avb-boot-sign";
  };
}
