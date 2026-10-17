# Installing NixOS on a phone

This is the device-independent part of the install. Device-specific facts
(partition names, unlock procedure, what works) live in the per-device page,
currently only [fairphone-fp5.md](./fairphone-fp5.md), which is also the
worked example below.

These instructions require `fastboot`. You can get it with
`nix-shell -p android-tools`. If some `fastboot` commands fail, try other USB
cables or ports; a multi-port external USB hub has worked where direct ports
did not.

## How this differs from a PC install

On a PC you flash the NixOS installer to a thumb drive, boot it, and let the
installer repartition the disk. With U-Boot we can use the same partition
layout we are used to on a PC, but it is not safe to repartition most Android
phones. Instead, existing partitions are reformatted to hold our data: the
NixOS images are built on your computer and flashed to those partitions with
`fastboot`, much like the installer is flashed to a thumb drive.

The plan:

1. Create a simple "install" NixOS configuration for the phone.
2. Use `disko` to build that configuration into flashable images.
3. Flash U-Boot to the phone.
4. Flash the NixOS images to the phone.
5. Boot into NixOS and customize your config.

## Prep work

- The bootloader must be unlocked. See the device page for the procedure.
- Read the device page's setup notes before building anything; some devices
  need the kernel cross-compiled rather than emulated.

## NixOS config

Copy `examples/installConfigs/<device>` from this repository into your NixOS
configuration (for the Fairphone 5: `examples/installConfigs/fairphone-fp5`).

Then:

- Add this repository and `disko` to your flake inputs.
- Add the example as a NixOS configuration.
- Import the `vanilla-mobile` and `disko` modules in that config.

A minimal flake:

`flake.nix`
```nix
{
  inputs = {
    # Use `nixos-unstable` as your nixpkgs version for this.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Don't set `inputs.nixpkgs.follows`, to avoid cache misses.
    vanilla-mobile-nixos.url = "github:gitman-101111/vanilla-mobile-nixos-fp5";
    disko = {
      # Use the disko fork until this PR is merged:
      # <https://github.com/nix-community/disko/pull/1008>
      url = "github:JuneStepp/disko/mobile";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { nixpkgs, vanilla-mobile-nixos, disko, ... }: {
    nixosConfigurations.fairphone-fp5 = nixpkgs.lib.nixosSystem {
      modules = [
        vanilla-mobile-nixos.nixosModules.vanilla-mobile
        disko.nixosModules.disko
        ./hosts/fairphone-fp5/configuration.nix
      ];
    };
  };
}
```

For Home Manager users there is an additional `homeManagerModules.vanilla-mobile`
module.

Notice that `./disko-config.nix` is imported by the example. That file defines
the filesystems that will be flashed to the phone and which phone partition
each image lands on. The Fairphone 5 example uses a LUKS-encrypted Btrfs root.
More layouts are in `examples/diskoConfigs`.

## Building the images

The phones are aarch64 devices. If you do not have an aarch64 build machine,
either cross-compile (`vanilla-mobile.installer.enableCrossPkgs = true`, the
recommended route for the Fairphone 5 since its kernel is not cached) or
enable binfmt emulation on your PC:

```nix
boot.binfmt.emulatedSystems = [
   (lib.mkIf (pkgs.stdenv.hostPlatform.system != "aarch64-linux") "aarch64-linux")
];
```

With binfmt you must also set `vanilla-mobile.installer.buildSystem` in the
phone config to the output of
`nix-instantiate --eval --expr "(import <nixpkgs> {}).stdenv.system"`.

The cache enabled in the install config only helps the build machine if it is
trusted there too:

```nix
nix.settings = {
  trusted-substituters = [
    "https://vanilla-mobile-nixos.cachix.org"
  ];
  trusted-public-keys = [
    "vanilla-mobile-nixos.cachix.org-1:nicMQxxTD4n6PM9dCvylqsCOCA6M2C6gybbCKrei8AQ="
  ];
};
```

Then add `--option extra-substituters https://vanilla-mobile-nixos.cachix.org`
to the build commands below.

Build the script that generates the images:

```
nix build --option extra-substituters https://vanilla-mobile-nixos.cachix.org \
  .#nixosConfigurations.fairphone-fp5.config.system.build.diskoImagesScript
```

Run it. Without LUKS that is just `./result`. With LUKS, pass the passphrase
through a temporary file:

```
bash -c 'read -s -p "LUKS Password: " p; tmp=$(mktemp); trap "rm \"$tmp\"" EXIT; echo "$p" > "$tmp"; ./result --pre-format-files "$tmp" /tmp/nixos-root.key'
```

This creates two images, `nixos-boot.raw` and `nixos-root.raw`.

## U-Boot

U-Boot provides the UEFI environment that standard tools like systemd-boot
expect. It is flashed to the phone's Android `boot` partition, which is
separate from the NixOS boot partition.

Build it:

```
nix build --option extra-substituters https://vanilla-mobile-nixos.cachix.org \
  .#nixosConfigurations.fairphone-fp5.config.vanilla-mobile.deviceInfo.uboot
```

Put the phone in fastboot mode and flash it. On an A/B device such as the
Fairphone 5, flash both slots:

```
fastboot flash boot_a result/u-boot.img
fastboot flash boot_b result/u-boot.img
```

Do not reboot yet.

## Flashing the NixOS images

Which Android partition each image goes to is documented at the top of the
device's `disko-config.nix`. For the Fairphone 5 the boot image goes to
`super` and the root image to `userdata`:

```
fastboot erase super
fastboot flash super nixos-boot.raw
fastboot erase userdata
fastboot flash userdata nixos-root.raw
fastboot reboot
```

The root flash may sit with no output for a while; be patient. Do not
interrupt the reboot or power-cycle the phone by hand.

## SSH access

Once booted, the install config exposes SSH over USB at
`ssh nixos@172.16.42.1`. With a strict SSH client config you may need:

```
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=yes -o PreferredAuthentications=password nixos@172.16.42.1
```

By default you lose SSH once you activate a non-install config. To keep SSH
available over USB only:

```nix
services.openssh = {
   enable = true;
   # Only allowing SSH over USB.
   openFirewall = false;
   listenAddresses = [
     {
       addr = config.vanilla-mobile.usb-gadget.network.serverAddress;
     }
   ];
 };
```

To use it, switch the phone to USB developer mode by choosing "Developer" in
the notification that appears when you plug it into a computer.

## Starter config

Remove the `vanilla-mobile.installer` section from your configuration, then
add the rest of your config. See [software-info.md](./software-info.md) for
desktop environment examples.

Send it over SSH and reboot:

```
nixos-rebuild boot --flake .#fairphone-fp5 --target-host "root@172.16.42.1"
```

After that, the device page describes day-to-day deployment (Wi-Fi SSH port,
kernel changes needing a reboot, and so on).
