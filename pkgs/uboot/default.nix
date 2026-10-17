# See <https://gitlab.postmarketos.org/tauchgang/tauchgang-ci/-/blob/main/devices.toml>
# for the information needed to add most new devices.
# Reference <https://gitlab.postmarketos.org/tauchgang/tauchgang-ci/-/blob/main/common.sh>
# if a new image building utility needs to be made.
{
  lib,
  ubootUtils,
  runCommand,
  ubootPackages,
  dtbtool-exynos,
}:
let
  inherit (ubootUtils)
    buildTauchgangUBoot
    mkAndroidBootImage
    mkAndroidBootImageV2
    mkAndroidBootImageQCDT
    ;
in
{
  # devices.toml:
  #   name = "Fairphone 5"
  #   maintainer = "Luca Weiss <lucaweiss@tauchgang.dev>"
  #   dtb = "qcom/qcm6490-fairphone-fp5"
  #   defconfig = "qcom_defconfig qcom-phone.config"
  #   android_bootimg_header_version = 2
  #   build_style = "qcom-phone"
  fairphone-fp5 = buildTauchgangUBoot {
    pname = "fairphone-fp5";
    dtb = "qcom/qcm6490-fairphone-fp5";
    defconfig = "qcom_defconfig qcom-phone.config";
  };
  # This device wants Android boot-image header version 2.
  fairphone-fp5-boot-image = mkAndroidBootImageV2 {
    uboot = ubootPackages.fairphone-fp5;
  };

  samsung-a2corelte = buildTauchgangUBoot {
    pname = "samsung-a2corelte";
    dtb = "exynos/exynos7870-a2corelte";
    defconfig = "exynos-mobile_defconfig";
  };
  samsung-a2corelte-boot-image = mkAndroidBootImageQCDT {
    uboot = ubootPackages.samsung-a2corelte;
    page_size = 2048;
    device_tree_image = runCommand "exynos-dtb-img" { } ''
      ${lib.getExe dtbtool-exynos} --output $out \
        ${ubootPackages.samsung-a2corelte}/u-boot.dtb
    '';
  };
}
