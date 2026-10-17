pkgs: self:
let
  inherit (pkgs) lib;
  inherit (self) callPackage;
  inherit (lib) recurseIntoAttrs;
in
{
  linuxKernels = recurseIntoAttrs (callPackage ./linux-kernel { });

  dtbtool-exynos = callPackage ./dtbtool-exynos { };
  ubootUtils = recurseIntoAttrs (callPackage ./uboot/utils.nix { });
  ubootPackages = recurseIntoAttrs (callPackage ./uboot { });

  # Firmware
  fairphone-fp5-firmware = callPackage ./fairphone-fp5-firmware { };
  ftharness = callPackage ./ftharness { };
  ffsupplicant = callPackage ./ffsupplicant { };
  libfprint-focaltech = callPackage ./libfprint { inherit (pkgs) libfprint; };
  pil-squasher = callPackage ./pil-squasher { };

  # FP5-only verified-boot tooling (docs/verified-boot.md).
  fairphone-fp5-verified-boot = recurseIntoAttrs (callPackage ./fairphone-fp5-verified-boot { });

  bootmac = callPackage ./bootmac { };
  unudhcpd = callPackage ./unudhcpd { };
  hexagonrpc = callPackage ./hexagonrpc { inherit (pkgs) hexagonrpc; };
  hyprgrass = callPackage ./hyprgrass { inherit (pkgs.hyprlandPlugins) hyprgrass; };
  iio-hyprland = callPackage ./iio-hyprland { };
  mobile-config-firefox = callPackage ./mobile-config-firefox { };
  pd-mapper = callPackage ./pd-mapper { };
  ssu-sysinfo = callPackage ./ssu-sysinfo { };
  swclock-offset = callPackage ./swclock-offset { };
  usb-moded = callPackage ./usb-moded { };
  usb-moded-notify = callPackage ./usb-moded-notify { };
  q6voiced = callPackage ./q6voiced { };
}
