# Verified-boot tooling for the Fairphone 5 (docs/verified-boot.md), kept in
# one device-specific scope: the FP5 is the only device here whose bootloader
# supports a custom AVB root of trust (avb_custom_key), so none of this
# belongs in the shared builders.
#
# - avb-boot-sign: sign the U-Boot boot image + vbmeta with the user's AVB
#   key, for relocking the bootloader.
# - uboot-efi-keys: generate UEFI Secure Boot certificates and the U-Boot
#   variable-store seed.
# - mkSecureBootImage: the FP5 boot image rebuilt with that seed embedded,
#   so U-Boot enforces UEFI Secure Boot on everything it loads.
{
  callPackage,
  ubootUtils,
  ubootPackages,
}:
{
  avb-boot-sign = callPackage ./avb-boot-sign.nix { };

  uboot-efi-keys = callPackage ./uboot-efi-keys.nix {
    ubootSrc = ubootPackages.fairphone-fp5.src;
  };

  # Function, not a package: the caller supplies the EFI variable seed built
  # from their own certificates (`uboot-efi-keys seed`). The seed carries
  # public certificates only, so it is safe in the store; with
  # EFI_VARIABLES_PRESEED the embedded PK/KEK/db cannot be changed at
  # runtime, and only EFI binaries signed by a db certificate will load.
  mkSecureBootImage =
    { efiVarSeed }:
    ubootUtils.mkAndroidBootImageV2 {
      uboot = ubootUtils.buildTauchgangUBoot {
        pname = "fairphone-fp5-secureboot";
        dtb = "qcom/qcm6490-fairphone-fp5";
        defconfig = "qcom_defconfig qcom-phone.config";
        extraConfig = ''
          CONFIG_FIT_SIGNATURE=y
          CONFIG_RSA=y
          CONFIG_EFI_SECURE_BOOT=y
          CONFIG_EFI_VARIABLES_PRESEED=y
          CONFIG_EFI_VAR_SEED_FILE="ubootefi.var"
        '';
        postPatch = ''
          cp ${efiVarSeed} ubootefi.var
        '';
      };
    };
}
