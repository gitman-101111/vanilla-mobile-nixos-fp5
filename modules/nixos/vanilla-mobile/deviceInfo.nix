{
  lib,
  ...
}:
{
  # Most of this information can be found in postmarketOS `deviceinfo` files.
  # Example: <https://gitlab.postmarketos.org/postmarketOS/pmaports/-/blob/main/device/community/device-fairphone-fp5/deviceinfo>
  options.vanilla-mobile.deviceInfo = {
    name = lib.mkOption {
      type = lib.types.str;
      example = "Fairphone 5";
    };
    codename = lib.mkOption {
      type = lib.types.str;
      example = "fairphone-fp5";
    };
    manufacturer = lib.mkOption {
      type = lib.types.str;
      example = "Fairphone";
    };

    dtb = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "qcom/qcm6490-fairphone-fp5.dtb";
      description = "Name of the device tree blob file";
    };
    # `rootfs_image_sector_size` in postmarketOS
    imageSectorSize = lib.mkOption {
      type = lib.types.int;
      default = 512;
      example = 4096;
      description = "Sector size used for the images to be flashed.";
    };
    firmware = lib.mkOption {
      type = with lib.types; nullOr package;
      default = null;
      description = "Device specific firmware.";
    };
    uboot = lib.mkOption {
      type = with lib.types; nullOr package;
      default = null;
      description = "What the user can flash to their phone to have UBoot.";
    };

  };
}
