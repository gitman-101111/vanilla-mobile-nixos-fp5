# Fairphone 5 (fairphone-fp5)

The Fairphone 5 is a Qualcomm QCM6490 (SC7280-class) device. This port runs a
mainline `linux_7_1` kernel with a set of board patches, plus userspace for the
Qualcomm remote processors, audio, NFC and fingerprint.

## Setup

The install follows the same shape as the other devices (see
[xiaomi-beryllium](./xiaomi-beryllium.md) for the general flow); the
device-specific facts are:

- Bootloader must be unlocked (`fastboot flashing unlock`).
- The example config is `examples/installConfigs/fairphone-fp5`
  (`configuration.nix` + `disko-config.nix`). Root is LUKS + Btrfs; the vendor
  `persist` partition is kept and mounted at `/persist`.
- Flashing is by partition (`fastboot flash`), not repartitioning. The A/B
  layout is retained; the config marks the booted slot good each boot.
- The kernel is not in any binary cache, so cross-compile it
  (`vanilla-mobile.installer.enableCrossPkgs = true`) rather than emulate.
  Note that cross-compiling the whole system (e.g. when a host config points
  at a local, uncached checkout) also cross-builds `libfprint-focaltech`,
  which trips a meson bug: `tests/meson.build` runs `unittest_inspector.py`
  against the freshly built aarch64 typelib on the x86 build host and fails.
  The `libfprint` package works around it by emptying the
  `virtual_devices_tests` loop; if you carry your own libfprint override,
  apply the same skip.
- The fingerprint trusted-application image is device-specific and unfree; it
  is not shipped here. Extract it from your own device's factory image with
  `pkgs/focal32-firmware/extract-from-factory.sh FP5-XXXX-factory.zip`, put the
  result inside your own configuration, and point the module at it with
  `vanilla-mobile.soc.qcm6490.fingerprint.firmwarePath`.

For security hardening (kernel hardening, module signing + lockdown,
hardened_malloc, auto-reboot when left locked, MAC randomization, login
throttling), set `vanilla-mobile.hardening.enable = true` — see
[hardening.md](./hardening.md).

The FP5 can additionally run a signed boot chain down to the kernel: U-Boot
enforcing UEFI Secure Boot on signed UKIs
(`vanilla-mobile.verifiedBoot`), confirmed on hardware
(`bootctl status` → `Secure Boot: enabled (user)`) while the bootloader stays
unlocked. Relocking on your own AVB key is a further step. See
[verified-boot.md](./verified-boot.md), including the `get_unlock_ability`
prerequisite and the bricking-avoidance checklist. Do not attempt it casually.

Once booted, deploy over Wi-Fi (SSH port 4440) or USB:

```
nixos-rebuild switch --flake .#<host> --target-host <user>@<ip> --use-remote-sudo
```

A kernel change requires a reboot to take effect; the root is LUKS, so the
initrd stops for a passphrase.

## What this port adds

On top of what mainline provides. Paths are relative to the repository root.

### Kernel (`pkgs/linux-kernel/fairphone-fp5/`)

| File | Purpose |
| --- | --- |
| `default.nix` | Kernel derivation: applies the patches below and sets the board `structuredExtraConfig` (camera, audio, NFC, TEE/QSEECOM, fingerprint, LUKS) |
| `fairphone-fp5-board-support.patch` | Board device tree, rear-camera (imx858) wiring and driver, board audio — imported from sc7280-mainline |
| `fp5-audio.dtsi`, `fp5-camera.dtsi` | Device-tree fragments referenced by the board-support patch |
| `imx858.c`, `imx858-kconfig` | Rear ultrawide camera sensor driver |
| `aw88261-and-q6afe-fixes.patch` | Speaker amp (aw88261) FROMLIST fixes + q6afe LPASS clock-vote fix; without them the speakers stay silent |
| `adc-tm5-processed-read.patch` | Fixes `adc_tm5_get_temp()` returning `-EINVAL` after the `iio_read_channel_processed()` convention change; restores the 8 PMIC thermal zones |
| `hci-qca-drop-unused-event.patch` | WCN6750 sends the baudrate-change complete event asynchronously; drops the spurious event so Bluetooth registers |
| `ptn36502-redriver-startup-delay.patch` | Gives the USB-C redriver rail settling time so DP/display probes reliably |
| `st21nfcd-nfc-driver.patch` | New `st21nfcd` raw-NCI I²C driver (the ST54-generation chip speaks NCI without NDLC framing, so `st-nci` cannot attach) + its DT node on `i2c9` |
| `tee-qseecom-driver.patch` | QSEECOM TEE driver (`drivers/tee/qseecom`) exposing legacy command-interface trusted applications through `/dev/tee*` |
| `tee-qseecom-align-response.patch`, `tee-qseecom-request-writeback.patch` | QSEECOM response-buffer fixes the fingerprint application needs |
| `qcom-scm-qseecom-fp5-allowlist.patch` | Adds `fairphone,fp5` to the SCM QSEECOM allowlist so the interface binds |
| `misc-focaltech-fp-driver.patch` | `focaltech-fp` misc driver owning the sensor's reset/power/interrupt GPIOs and exposing `/dev/focaltech_fp` |
| `dts-fp5-fingerprint-sensor.patch` | Fingerprint DT node + pinctrl states |

### SoC / device modules (`modules/nixos/vanilla-mobile/soc/qcm6490/`)

| File | Purpose |
| --- | --- |
| `default.nix` | qcm6490 module: options `audio`/`modem`/`sensors`/`nfc`/`fingerprint`; wires hexagonrpcd, the sensor stack, `/persist`, neard, ffsupplicant, focal32-load, fprintd and PAM |
| `fairphone-fp5.nix` | Device definition: partitions, firmware, U-Boot, accel mount matrix, mutter overlay, enables the qcm6490 SoC + NFC |
| `mutter-portrait-autorotate.patch` | Backport of the upstream mutter fix for a portrait device with no tablet-mode switch, enabling native auto-rotation |
| `iio-sensor-proxy-wait-for-hotplug.patch` | Keeps iio-sensor-proxy alive when no SSC sensor exists at startup; udev cannot re-trigger the service for SSC sensors, which are not kernel devices |
| `fp5-ucm/` | ALSA UCM profile (speaker, mic, DP) |

### Packages (`pkgs/`)

| File | Purpose |
| --- | --- |
| `fairphone-fp5-firmware/` | Device firmware (DSP, modem, GPU, etc.) |
| `pd-mapper/` | Userspace PD mapper (NOT used by this device — the in-kernel `qcom_pd_mapper` serves the maps; see "Sensor bring-up". Kept as a reusable module/package) |
| `hexagonrpc/` | hexagonrpcd (ADSP FastRPC), which serves the SSC its sensor registry (the nested `/persist` factory registry, copied into place — see "Sensor bring-up" below) |
| `pil-squasher/` | Assembles split firmware into `.mbn` images |
| `focal32-firmware/extract-from-factory.sh` | Extracts the fingerprint trusted application from a factory zip; the image itself is user-provided via `fingerprint.firmwarePath` |
| `ftharness/` | Client for the fingerprint trusted application over the QSEECOM TEE driver (load, init, command); built from [fp5-fingerprint-tools](https://github.com/marcusramberg/fp5-fingerprint-tools) |
| `ffsupplicant/` | Serves the trusted application's RPMB + gpfile secure-storage listeners; built from [fp5-fingerprint-tools](https://github.com/marcusramberg/fp5-fingerprint-tools) |
| `libfprint/` | libfprint with the FocalTech-QSEE driver, so fprintd can see the sensor |

## Sensor bring-up (ADSP / SSC)

The accelerometer, ambient-light, proximity and compass sensors live on the
ADSP's sensor protection domain (SSC). `hexagonrpcd-adsp-sensorspd` attaches to
it over FastRPC and serves it a hexagonfs tree rooted at `/run/hexagon-adsp`,
staged from the firmware's `hexagonfs/` by the unit's `ExecStartPre`. The DSP
reads its registry (per-sensor config + factory calibration) through that tree
during init; if the read fails it asserts in `SNS_REG_TASK`
(`sns_registry_sensor.c:154: SNS_RC_SUCCESS == rc`), and the resulting ADSP
crash/recovery can cascade into a watchdog reboot loop.

Two things matter for a reliable attach:

- **Nested registry, copied from `/persist` (not bind-mounted).** The DSP opens
  the mapped `sensors/registry/` and then a *nested* `registry/` child inside it
  (`openat(dir, "registry")` — confirmed by `strace`); the factory registry
  items live at `sensors/registry/registry/<item>`. That is the `/persist`
  layout: `/persist/sensors/registry/` holds `registry/` (the items) plus
  `sns_reg_version`. The firmware hexagonfs ships `sensors/registry` FLAT (items
  directly in it, no nested `registry/`), so the DSP's nested open returns
  `ENOENT`, it asserts in `SNS_REG_TASK`, and the ADSP crashes. So the
  root-builder copies the `/persist` registry into the nested position:
  `mkdir -p $root/sensors/registry/registry && cp -r /persist/sensors/registry/registry/. …`
  plus `sns_reg_version`, then `chmod -R u+w`. It is a **file copy, not a
  `mount --bind`**: a privileged (`+`) ExecStartPre bind mount happens in the
  host mount namespace and does **not** reliably propagate into the daemon's
  sandboxed namespace (it appeared to work post-boot but not on a cold boot),
  whereas files written into the RuntimeDirectory tmpfs are always visible to
  the daemon. The copy makes runtime-cal write-back ephemeral (per boot) rather
  than persisted, which is fine — the factory calibration is copied in fresh
  each boot.
- **PD maps are served by the in-kernel mapper, ordered by construction.**
  A DSP performs its service-registry lookup shortly after it boots; if no
  mapper is answering at that moment its protection domains never register:
  the ADSP then has no APR audio services (so the LPASS `core` clock never
  appears and the entire soundcard probe chain sits in deferred-probe — no
  audio, and via pmic_glink no battery reporting either), the WPSS brings up
  no Wi-Fi adapter, the sensor PD attaches but streams no data, and
  `msm-modem-uim-selection` fails. This port uses the kernel's
  `qcom_pd_mapper` (an auxiliary device spawned by the `qcom_q6v5_pas`
  remoteproc driver itself, with the qcm6490/sc7280 maps built in), so the
  mapper is answering before any DSP can look anything up — the ordering
  cannot be lost. Exactly one mapper may run: the userspace `pd-mapper`
  daemon must stay disabled, since two publishers storm the pdr notifier and
  intermittently crash q6afe probe into a watchdog boot loop. The userspace
  daemon is also structurally unable to provide the ordering on its own: it
  discovers which maps to load by walking `/sys/class/remoteproc`, so it
  needs the remoteprocs to exist first, while the DSPs need it answering
  before they boot — its first start fails ("no pd maps available") and its
  restart races the DSP lookups.
  The sensor daemon's `ExecStartPre` additionally waits for the ADSP
  remoteproc to report `running` plus a settle, with a bounded, spaced retry
  policy (`startLimitBurst`/`RestartSec`) so even a failed attach cannot hold
  up or storm the boot.

To reproduce/debug an attach by hand (root), stage the tree the way the unit
does and run the daemon directly, watching `dmesg` for `crash detected in adsp`
and the daemon's stderr for `Could not open`:

```
root=/run/hexagon-adsp-test; fw=$(ls -d /nix/store/*fairphone-fp5-firmware*/lib/firmware/qcom/*/*/hexagonfs)
mkdir -p "$root"; cp -r "$fw/." "$root/"
mkdir -p "$root/sensors/registry/registry" "$root/vendor/etc/sensors"
cp -r /persist/sensors/registry/registry/. "$root/sensors/registry/registry/"
cp "$fw/sensors/sns_reg.conf" "$root/vendor/etc/sensors/sns_reg_config"
chmod -R u+w "$root/sensors/registry"
hexagonrpcd -f /dev/fastrpc-adsp -d adsp -R "$root" -s
```

A single manual attach is safe (the ADSP recovers from one crash); it is the
repeated automatic re-attaches that exhaust the DSP's protection-domain slots.
Note: a bind-mount test in a plain shell will *seem* to work because a plain
shell shares the host namespace — the propagation failure only shows up under
the service's sandbox, so validate with the real unit.

## Hardware support

Confirmed = verified working on hardware.

| Subsystem | Confirmed | Notes |
| --- | :---: | --- |
| Display + backlight | yes | Requires `deferred_probe_timeout=-1` |
| GPU (Adreno 660) | yes | |
| Touchscreen (Goodix Berlin) | yes | |
| Wi-Fi (ath11k WCN6750) | yes | On AHB, not PCI |
| Bluetooth (WCN6750) | yes | Needs `hci-qca-drop-unused-event`; wake-on-BT masked |
| Battery + charging | yes | |
| Suspend / resume | yes | Deep sleep; BT wake interrupt masked |
| Storage (LUKS Btrfs + `/persist`) | yes | |
| Accelerometer + auto-rotation | yes | Native GNOME/mutter auto-rotation |
| Ambient light sensor | yes | |
| Proximity sensor | yes | |
| Speakers | yes | Needs `aw88261-and-q6afe-fixes` |
| Microphone | yes | |
| Haptics (aw86927) | yes | |
| Rear ultrawide camera (imx858) | yes | With autofocus (dw9719) |
| Front camera (s5kjn1) | yes | |
| Camera flash LED | yes | |
| Thermal (8 PMIC zones) | yes | Needs `adc-tm5-processed-read` |
| NFC (ST21NFC) | yes | `st21nfcd` driver + neard; tag reading |
| USB-C DisplayPort out | yes | Single head; no MST |
| USB gadget (ACM / NCM) | yes | |
| A/B slot handling | yes | `qbootctl -m` each boot |
| GNSS/GPS | yes | Position fix via ModemManager (Qualcomm `PQWP2`); exposed to the desktop through geoclue |
| Modem (voice/SMS/data) | partial | Registers; calls need q6voiced card/device numbers |
| Fingerprint (FocalTech FT9362) | yes | Enroll, match and PAM unlock via the TrustZone application (focal32) over QSEECOM |
| Main rear camera (IMX800) | no | No driver on any mainline OS |
| NFC card emulation / secure element | no | Not wired |
