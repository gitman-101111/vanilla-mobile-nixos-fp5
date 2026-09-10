self:
{
  lib,
  config,
  ...
}:
let
  cfg = config.hardware.usb-gadget;
in
{
  options.hardware.usb-gadget = {
    enable = lib.mkEnableOption "usb-gadget";

    gadgetName = lib.mkOption {
      type = lib.types.str;
      default = "g1";
    };
    usbManufacturer = lib.mkOption {
      type = lib.types.str;
      default = "NixOS";
    };
    usbProduct = lib.mkOption {
      type = lib.types.str;
    };
    usbSerialNumber = lib.mkOption {
      type = lib.types.str;
      default = "NixOS";
    };
  };

  config = lib.mkIf cfg.enable {

    # For USB gadget config.
    boot.initrd.kernelModules = [ "libcomposite" ];

    networking.firewall.trustedInterfaces = [ "usb0" ];

    systemd.services.usb-gadget = {
      unitConfig.DefaultDependencies = false;
      requires = [
        "sys-kernel-config.mount"
        "modprobe@libcomposite.service"
      ];
      after = [
        "systemd-modules-load.service"
        "sys-kernel-config.mount"
        "modprobe@libcomposite.service"
      ];
      wantedBy = [ "basic.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # Create USB gadget with ConfigFS.
      # See <https://www.kernel.org/doc/html/latest/usb/gadget_configfs.html> for
      # details on how this works.
      script = ''
        GADGET="/sys/kernel/config/usb_gadget/${cfg.gadgetName}"

        # mkdir -p / guarded ln / bind-if-unbound: a failed run leaves the
        # gadget tree half-created, and a restart must pick it up.
        mkdir -p $GADGET
        # Set to vendor ID for "Linux Foundation".
        echo "0x1d6b" > $GADGET/idVendor
        # Set to product ID for "Multifunction Composite Gadget".
        echo "0x0104" > $GADGET/idProduct

        # Create English (0x409) strings directory.
        mkdir -p $GADGET/strings/0x409
        echo "${cfg.usbManufacturer}" > $GADGET/strings/0x409/manufacturer
        echo "${cfg.usbProduct}" > $GADGET/strings/0x409/product
        echo "${cfg.usbSerialNumber}" > $GADGET/strings/0x409/serialnumber

        # Create network function.
        mkdir -p $GADGET/functions/ncm.usb0

        # Create `c` configuration `1`.
        mkdir -p $GADGET/configs/c.1
        # Create `c.1` config's English (0x409) strings directory.
        mkdir -p $GADGET/configs/c.1/strings/0x409
        echo "USB network" > $GADGET/configs/c.1/strings/0x409/configuration

        # Link the network instance to the configuration.
        [ -e $GADGET/configs/c.1/ncm.usb0 ] \
          || ln -s $GADGET/functions/ncm.usb0 $GADGET/configs/c.1/

        # Link the gadget instance to a USB Device Controller, activating the
        # gadget. The UDC appears only once the controller and PHYs finish
        # probing, which can be after this unit runs.
        udc=
        for _ in $(seq 1 30); do
          udc=$(ls /sys/class/udc 2>/dev/null | head -1)
          [ -n "$udc" ] && break
          sleep 1
        done
        if [ -z "$udc" ]; then
          echo "usb-gadget: no UDC appeared after 30s" >&2
          exit 1
        fi
        # Writing to UDC while already bound returns EBUSY.
        if [ -z "$(cat $GADGET/UDC 2>/dev/null)" ]; then
          echo "$udc" > $GADGET/UDC
        fi
      '';

      restartIfChanged = false;
    };

  };

  meta.maintainers = [ lib.maintainers.junestepp ];
}
