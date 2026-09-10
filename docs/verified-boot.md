# Verified boot on the Fairphone 5

The FP5's bootloader supports a user-settable root of trust: flash your own
public key to the `avb_custom_key` partition and relock, and the Qualcomm
bootloader (ABL) enforces Android Verified Boot against **your** key. CalyxOS
ships on the FP5 this way; this port can use the same mechanism, and because
what lives in the `boot` partition here is U-Boot, the chain can be extended
past it with UEFI Secure Boot:

```
ABL ──AVB, your avb_custom_key──▶ boot partition: U-Boot
     └─UEFI Secure Boot, your db key──▶ systemd-boot (signed)
         └─────────────────────────────▶ UKI (kernel + initrd + cmdline
                                              + devicetree, one signed PE)
             └─────────────────────────▶ LUKS passphrase → rootfs
```

## Status: what is proven, what is still ahead

This has been brought up on real hardware. The two halves are at different
stages:

- **UEFI Secure Boot in U-Boot — proven and enforcing.** With the enforcing
  U-Boot flashed, `bootctl status` reports `Secure Boot: enabled (user)` and
  the phone boots only because systemd-boot and the UKI carry a valid `db`
  signature. Kernel, initrd, kernel command line and device tree are all
  inside the signed UKI, so the ESP is no longer trusted input: an edited
  command line, swapped initrd or stale kernel fails verification in U-Boot.
  This half runs with the bootloader **unlocked**.
- **AVB relock (locking the bootloader) — a procedure to follow, below.** The
  `avb_custom_key` can be pre-flashed; completing the lock needs a *correct*
  full vbmeta (see [the vbmeta lesson](#phase-c--avb-custom-key-and-the-vbmeta-lesson))
  and carries the wipe/brick risks called out below. Until you lock, the security comes entirely from the U-Boot half
  above.

So an evil maid cannot swap the kernel, initrd, command line or device
tree (all in the signed UKI, verified by U-Boot). Once you also lock, they
additionally cannot reflash `boot` with a keylogging U-Boot.

**Honest residual gaps** — what this does *not* give you, even after locking:

- **Rollback protection** beyond the AVB `--rollback-index` on the boot
  image. An attacker with ESP access can select an *older signed* generation
  (the loader menu and `loader.conf` are unsigned), so old kernels with known
  holes remain selectable until you prune them.
- **Attestation.** Nothing measures the boot for remote verification.
- **EDL.** Qualcomm's emergency download mode sits below all of this; it
  requires a Qualcomm/Fairphone-signed loader, which is the same trust
  situation as any Android phone.
- ESP tampering is still a denial of service (verification refuses to boot);
  the protection is against *undetected* modification, not vandalism.

The tooling splits along the device boundary: the NixOS module
`vanilla-mobile.verifiedBoot` (`modules/nixos/vanilla-mobile/verified-boot.nix`)
is **device-agnostic** — it signs systemd-boot and per-generation UKIs with
the `db` key at switch time and works on any device whose bootloader chain
enforces UEFI Secure Boot. What is FP5-specific is the bootloader half:
`pkgs/fairphone-fp5-verified-boot/` (build with
`nix build '.#fairphone-fp5-verified-boot/avb-boot-sign'` and
`'.#fairphone-fp5-verified-boot/uboot-efi-keys'`) produces the AVB-signed,
key-seeded U-Boot image and is pulled onto the device by the FP5 device
module when `verifiedBoot.enable` is set. Another U-Boot device can adopt the
module by providing its own enforcing U-Boot and `db` keys.

A hard requirement for any signing tool here: the signed image must embed the
generation's *own* devicetree (applied via U-Boot's EFI_DT_FIXUP). The FP5
kernels carry DT patches, so a generation must boot with the DTB it was built
with, not whichever one U-Boot ships — generic secure-boot tooling that
signs only kernel and initrd and leaves the DTB to the firmware cannot
satisfy this.

## The one rule that prevents a brick

> **Never run `fastboot flashing lock` unless
> `fastboot flashing get_unlock_ability` prints `1`.**

If the device is locked, refuses to boot your image, *and* unlock ability is
0, it is dead — this is the known Fairphone bootloader failure mode. Check it
at every step. If it ever reads 0, stop and do not lock; restore it first (see
the prerequisite below).

Everything before the final lock step is reversible over fastboot while the
bootloader is unlocked.

## Prerequisite — restore `get_unlock_ability` (a phone with no Android reads 0)

On a device that no longer runs Android, `fastboot flashing get_unlock_ability`
returns **0**, because that flag is normally set by Android's "OEM unlocking"
toggle. Locking in that state is the brick above, so fix it first.

The FP5 ABL (confirmed by extracting the device's own `abl.elf`) reads **only
the last byte of the `frp` partition** — bit `0x01` — with no checksum. `frp`
is a fastboot *critical* partition, so `fastboot flash frp` needs
critical-unlock, which is itself gated on this same flag — a chicken-and-egg.
The reliable path is to write it **from the running OS**:

```
# Back up first — always.
sudo dd if=/dev/disk/by-partlabel/frp of=~/frp.backup.bin bs=4096
sudo blockdev --getsize64 /dev/disk/by-partlabel/frp   # expect 524288

# Set the last byte's low bit. Partition is 524288 bytes → seek 524287.
printf '\x01' | sudo dd of=/dev/disk/by-partlabel/frp bs=1 seek=524287 \
  conv=notrunc,fsync
sync
```

Reboot to fastboot and confirm `get_unlock_ability` now prints `1`. It reads
the flag once at fastboot start. Only Android's PersistentDataBlockService
validates the partition's digest and would reset the flag on an Android boot —
irrelevant once Android is gone, so this sticks. (Fairphone's own factory
`frp_for_factory.img` is exactly 512 KiB of zeros with a trailing `0x01`.)

## Phase A — recon (safe, do first)

In fastboot mode (`fastboot` from `nix-shell -p android-tools`):

```
fastboot flashing get_unlock_ability   # must print 1 (see prerequisite)
fastboot getvar partition-size:boot_a  # expect 0x6000000 (100663296)
fastboot getvar current-slot
```

The signing default assumes the 96 MiB boot partition; pass
`--partition-size` to `avb-boot-sign sign` if yours differs.

## Phase B — UEFI Secure Boot, while still unlocked (the proven, enforcing half)

Every part of this is undoable over fastboot while unlocked.

1. **Generate Secure Boot keys** (ideally on an offline machine):

   ```
   uboot-efi-keys keygen sb-keys
   uboot-efi-keys seed --keys sb-keys --out ubootefi.var
   ```

   `PK.key`/`KEK.key` are only ever needed to make a new seed — keep them
   offline. `db.key`+`db.crt` sign bootloaders and kernels and must reach the
   phone. The seed file holds public certificates only.

2. **Put the db pair on the phone**, on the encrypted root:

   ```
   sudo install -d -m 0700 /etc/verified-boot
   sudo install -m 0600 sb-keys/db.key /etc/verified-boot/
   sudo install -m 0644 sb-keys/db.crt /etc/verified-boot/
   ```

3. **Enable signed UKIs** in the phone's configuration and switch:

   ```nix
   vanilla-mobile.verifiedBoot.enable = true;
   ```

   This replaces the systemd-boot install with a signing install hook: at
   switch time it signs systemd-boot and builds one signed UKI per generation
   (kernel, initrd, cmdline and DTB in one PE) with `/etc/verified-boot/db.key`.
   Signed binaries boot fine under the current *non*-enforcing U-Boot, so
   switch and reboot now to confirm the UKI path works before any enforcement
   exists. Confirm with `bootctl status` (`Current Stub` should point at
   `/EFI/Linux/nixos-generation-N.efi`) and by reading `LoaderEntrySelected`.
   If the panel stays dark on a UKI boot, retry with
   `verifiedBoot.embedDevicetree = false` — that means the DTB U-Boot provides
   was the working one, which is worth reporting.

   Two module details worth knowing:

   - The pre-existing plain systemd-boot entries are **kept as a fallback**
     until a signed UKI is confirmed to have actually booted. A
     `verified-boot-confirm-uki` service watches `LoaderEntrySelected` and
     stamps the ESP once a UKI is seen; only then does the next switch retire
     the legacy entries. So a first UKI that fails to boot still leaves a
     working entry in the menu.
   - That confirm service is ordered with `RequiresMountsFor` on the ESP —
     without it, it can run during very early boot before `/boot` is mounted
     (and before the RTC offset is applied), and the stamp write is lost.

4. **Build the enforcing U-Boot** — the stock FP5 U-Boot rebuilt with your
   variable store embedded (`EFI_VARIABLES_PRESEED`: PK/KEK/db cannot be
   altered at runtime; only db-signed binaries load). From a checkout of this
   repository:

   ```
   nix build --impure --expr '
     let
       flake = builtins.getFlake (toString ./.);
       d = import (flake.outPath + "/default.nix") { inherit flake; system = builtins.currentSystem; };
       scope = d.getPackages d.pkgs.pkgsCross.aarch64-multiplatform;
     in scope.fairphone-fp5-verified-boot.mkSecureBootImage {
       efiVarSeed = /absolute/path/to/ubootefi.var;
     }'
   ```

5. **Flash it and verify enforcement** (still unlocked — a bad image is fixed
   by reflashing the stock `fairphone-fp5-boot-image`). Flash **only the boot
   partitions**; leave vbmeta alone (see phase C for why):

   ```
   fastboot flash boot_a result/u-boot.img
   fastboot flash boot_b result/u-boot.img
   fastboot reboot
   ```

   On the running phone, `bootctl status` should report
   **`Secure Boot: enabled (user)`** and `LoaderEntrySelected` should name a
   `nixos-generation-N.efi` UKI — this is the confirmed working end state.

   **Negative test** (proves rejection, not just acceptance): put an *unsigned*
   `.efi` in `/boot/EFI/Linux/` — e.g. copy a UKI and strip its signature with
   `sbattach --remove`. Note `bootctl set-oneshot` does **not** work under the
   enforcing U-Boot: it writes an EFI variable, and this U-Boot exposes no
   runtime variable writes, so `efivarfs` is mounted read-only. Instead leave
   the signed generation as `default` in `loader.conf` (so an unattended boot
   stays safe), widen `timeout`, reboot, and at the systemd-boot menu manually
   select the unsigned entry. Confirmed on hardware: U-Boot refuses it with a
   *Security Policy Violation* and returns to the menu, where the signed entry
   boots normally. Delete the unsigned file and restore `timeout` afterwards.

## Phase C — AVB custom key, and the vbmeta lesson

This half is what a future **lock** builds on. It is **not** required for the
Secure Boot enforcement of phase B, and it comes with a hardware caveat learned
the hard way.

**The vbmeta lesson (important):** the FP5 ABL marks a slot **unbootable** if
its vbmeta carries a hash descriptor that doesn't match the *full* set the ABL
expects — and it does this **even while unlocked**. Unlocking only skips AVB
*enforcement* (verification failure won't stop boot); it does **not** skip this
consistency check. The single-partition vbmeta that `avb-boot-sign sign`
produces (it describes only `boot`) is enough to mark the slot unbootable. In
testing this bricked a slot; recovery was a **verification-disabled** vbmeta:

```
avbtool make_vbmeta_image --flags 2 --padding_size 4096 --output vbmeta_disabled.img
fastboot flash vbmeta_a vbmeta_disabled.img
fastboot flash vbmeta_b vbmeta_disabled.img
fastboot --set-active=a
fastboot reboot
```

So **while unlocked, keep a `--flags 2` (verification-disabled) vbmeta** and
let U-Boot's embedded Secure Boot be the whole story. You can still pre-flash
your public AVB key so it is in place for a later lock:

```
avb-boot-sign keygen avb-keys
fastboot erase avb_custom_key
fastboot flash avb_custom_key avb-keys/avb_pkmd.bin
```

`avb-boot-sign sign` still correctly produces `signed/boot.img` (a boot image
with an AVB hash footer); it is the accompanying single-partition
`signed/vbmeta.img` that must **not** be flashed to an FP5 while relying on it
for boot. A correct full vbmeta that replicates the stock descriptor set is
**a prerequisite for locking** — see phase D.

## Phase D — locking

The final step. It has two prerequisites: a correct full vbmeta (phase C), and
accepting the wipe risk below. Do it once those are met.

**Open hardware question, plan for it:** on stock Android, toggling the lock
state factory-resets userdata. Our LUKS root *lives on the userdata
partition*. Whether the FP5's lock actually erases it in a setup with no
Android recovery is exactly what the first lock test must answer — assume it
does. The ESP (`system` partition) and everything flashed above survive either
way.

Pre-lock checklist:

- [ ] A **correct full vbmeta** (not the single-partition one) is flashed to
      both slots and the phone boots with it.
- [ ] Phone boots, `bootctl status` shows `Secure Boot: enabled (user)`.
- [ ] `fastboot flashing get_unlock_ability` prints `1`.
- [ ] Everything on the phone you care about is backed up off the phone.

Then:

```
fastboot flashing lock
```

Confirm on the device screen. Two outcomes:

- **Root survived:** done. The boot chain is now enforced end to end, including
  `boot`. Expect the bootloader's "custom OS/key" notice at power-on — that is
  the yellow boot state working as designed.
- **Root was wiped:** the chain still verifies (U-Boot and the ESP are intact)
  but there is no rootfs. Recovery: `fastboot flashing unlock` (permitted —
  unlock ability is 1; wipes what is already wiped), reinstall per
  [fairphone-fp5.md](./fairphone-fp5.md), and redo phases C + D — the
  wipe-on-lock only bites the *first* time, because from then on updates happen
  from inside the OS (below) and the device never unlocks again. If this
  outcome occurs, a pre-staged signed rescue UKI on the ESP (with SSH over USB
  networking) would allow installing the root *after* locking; that is the
  designed follow-up if the test confirms the wipe.

## Day-2 operation

- **System and kernel updates are unaffected.** `nixos-rebuild switch` builds
  and signs a new UKI on the ESP; the boot partition isn't involved. (The HM
  activation and services keep working; the deploy just needs to reach the
  phone — see the MAC note below.)
- **U-Boot / Secure Boot key changes** while locked cannot go through fastboot,
  and don't need to: root can write the partitions from the running OS, which
  is how Android OTAs update locked devices too. Build + sign the new image
  (phases B4 + C — `avb-boot-sign` also runs on the phone), then:

  ```
  # write the INACTIVE slot first, reboot into it, then do the other
  dd if=signed/boot.img of=/dev/disk/by-partlabel/boot_b bs=4096 conv=fsync
  ```

  A/B plus `qbootctl` gives a fallback: if the new slot fails to boot, the
  bootloader falls back to the other one after the retry counter runs out.
- **Rollback hygiene:** old signed UKIs remain bootable; `configurationLimit`
  (default 5) bounds how far back an attacker with ESP access can roll you.
  After a security-relevant kernel fix, collect garbage and switch so old
  generations (and their UKIs) disappear.
- **Stable IP for remote deploys:** NetworkManager's default per-connection MAC
  randomization hands the phone a new DHCP lease (new IP) on every reconnect,
  which breaks `--target-host` deploys mid-session. Pin a stable/cloned MAC for
  your home SSID (`nmcli connection modify <ssid>
  802-11-wireless.cloned-mac-address <mac>`, or the `hardening` module's
  `stable-ssid` mode) so the IP holds.
- **Key custody:** `avb.pem`, `PK.key`, `KEK.key` stay offline. `db.key` has to
  live on the phone (UKIs are signed at switch time) — it sits on the LUKS
  root, so it is protected by exactly the boundary the chain defends. A root
  compromise of the *running* system can sign kernels with it, but a root
  compromise already owns the running system; verified boot's job is the
  powered-off phone, and that it still does.

## Recovery matrix

| Situation | State | Way out |
| --- | --- | --- |
| Bad signed UKI / config | unlocked or locked | Pick an older generation in the boot menu |
| Secure-boot U-Boot won't boot | unlocked | `fastboot flash boot_{a,b}` the stock `fairphone-fp5-boot-image` |
| Slot marked unbootable after a vbmeta flash | unlocked | Flash a `--flags 2` disabled vbmeta to both slots, `fastboot --set-active=a` |
| AVB verification fails after lock | locked, unlock ability 1 | `fastboot flashing unlock` (wipes userdata), reflash, start over |
| Wrote a bad boot image from the OS | locked | Reboot; A/B falls back to the untouched slot |
| `get_unlock_ability` reads 0 | unlocked | Restore it from the OS (see prerequisite) **before** any lock |
| Anything, unlock ability 0 | locked | **This is the brick.** Prevented by the checklist; only EDL could help |
