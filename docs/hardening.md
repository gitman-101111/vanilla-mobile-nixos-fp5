# Security hardening

The `vanilla-mobile.hardening` module carries the security hardening a stock
Linux stack can apply on this platform. Enable it from a host configuration:

```nix
vanilla-mobile.hardening.enable = true;
```

Every sub-feature below is then on by default (except hardened_malloc) and
individually toggleable under `vanilla-mobile.hardening.*`.

## What it does

### Kernel hardening (`kernel`)

Kernel attack-surface reduction available in mainline, split across runtime
knobs (this module) and compile-time options (baked into the FP5 kernel's
`structuredExtraConfig`, which is why they live in the kernel package rather
than here).

Runtime, from this module:

- Command line: `init_on_alloc=1 init_on_free=1 slab_nomerge
  page_alloc.shuffle=1 randomize_kstack_offset=on iommu.strict=1`.
- Sysctls (each overridable by a plain assignment in a host config):
  restricted `dmesg` and kernel pointers, `perf_event_paranoid=3`,
  unprivileged eBPF off + JIT hardening, io_uring disabled, Yama ptrace
  scoping, no TTY line-discipline autoload, no unprivileged userfaultfd, no
  setuid core dumps, sticky-directory fifo/regular protections, and the
  ICMP-redirect/source-route network hygiene set.
- `security.protectKernelImage` (no kexec, no hibernation — these devices
  suspend instead anyway) and the systemd-boot editor disabled, so nobody can
  type `init=/bin/sh` at the boot menu.
- Legacy protocol modules (ax25, dccp, sctp, tipc, …) blacklisted.

Compile-time, in the FP5 kernel (the KSPP-recommended config block — the
build-time counterparts of the runtime knobs above):

- Self-protection: `FORTIFY_SOURCE`, `STACKPROTECTOR_STRONG`, full KASLR
  (`RANDOMIZE_BASE` + `RANDOMIZE_MODULE_REGION_FULL`), heap and page-allocator
  randomisation (`SLAB_FREELIST_RANDOM`, `SLAB_FREELIST_HARDENED`,
  `SHUFFLE_PAGE_ALLOCATOR`), and zero-on-alloc/free compiled on by default
  (`INIT_ON_ALLOC_DEFAULT_ON`, `INIT_ON_FREE_DEFAULT_ON`).
- Integrity: read-only kernel and module text/data (`STRICT_KERNEL_RWX`,
  `STRICT_MODULE_RWX`, `DEBUG_WX`), panic-on-corruption
  (`BUG_ON_DATA_CORRUPTION`), bounds-checked usercopy (`HARDENED_USERCOPY`),
  `SCHED_STACK_END_CHECK`.
- Reduced disclosure/surface: `PROC_KCORE=n`, `LEGACY_PTYS=n`,
  `SECURITY_DMESG_RESTRICT`.

### Kernel module signing (compile-time)

The FP5 kernel is built with `MODULE_SIG` + `MODULE_SIG_ALL` +
`MODULE_SIG_FORCE` + SHA-512: every in-tree module is signed with an ephemeral
key generated at build time, and the kernel refuses to load an unsigned
module. The signed UKI (see [verified-boot.md](./verified-boot.md)) already
covers the kernel and the initrd's modules; module signing extends that to
modules loaded later from the (mutable) rootfs, closing the one module-load
path the UKI signature does not reach. All of this port's drivers are in-tree,
so they are all signed by this — no out-of-tree kmod is left unable to load.

### Lockdown LSM (compile-time + `lsm=`)

The kernel compiles in the lockdown LSM and forces confidentiality mode from
early boot (`SECURITY_LOCKDOWN_LSM`, `SECURITY_LOCKDOWN_LSM_EARLY`,
`LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY`); the module appends
`lsm=landlock,lockdown,yama,bpf` (via `mkAfter`, so it wins over the base
`lsm=` nixpkgs emits) so the LSM actually initialises. Confidentiality mode
blocks even root from reading kernel memory, loading unsigned modules, and
`kexec`. It pairs with the enforcing UEFI Secure Boot chain from
[verified-boot.md](./verified-boot.md): Secure Boot guarantees the kernel that
boots, and lockdown keeps a running root from tampering with it.

### hardened_malloc (`memoryAllocator`)

`environment.memoryAllocator.provider = "graphene-hardened"` — the
hardened_malloc allocator, system-wide. Recommended and flipped on for the FP5
(the host config sets `memoryAllocator.enable = true`). It costs some memory and
performance and a few programs misbehave under it; if a GUI app breaks, fall
back to the less aggressive `graphene-hardened-light` provider before turning
it off entirely.

### Auto-reboot (`autoReboot`)

If no session is unlocked and no SSH session is open for `autoReboot.hours`
(default 18), the phone reboots and waits at the LUKS passphrase prompt —
templates, keys and user data all back behind before-first-unlock encryption.
An RTC wake alarm is armed so the deadline holds even while the phone sleeps.

### Radio privacy (`macRandomization`, `bluetoothPrivacy`)

- Wi-Fi: randomized scanning MAC plus `wifi.cloned-mac-address` set from
  `macRandomization.mode` — `random` (a new MAC per connection) or
  `stable-ssid` (one stable MAC per network). `stable-ssid` is the practical
  choice for a device that is deployed to remotely: no single hardware MAC is
  broadcast across networks, while each network hands out a stable DHCP lease
  (a per-connection random MAC gets a new IP on every reconnect, which
  disrupts remote deploys). Note the derivation is keyed by NetworkManager's
  `/var/lib/NetworkManager/secret_key`, so the per-network MAC (and the IP)
  changes after a full wipe unless that key is persisted.
- Bluetooth: BlueZ `Privacy=device`, using resolvable private addresses
  instead of the fixed hardware address.

### Network privacy (`networkPrivacy`, on by default)

- IPv6 **temporary (privacy) addresses** (`networking.tempAddresses`), so
  outbound v6 traffic is not tied to a stable interface identifier.
- **DNS over TLS**, opportunistically, via systemd-resolved
  (`services.resolved.settings.Resolve.DNSOverTLS = "opportunistic"`) — captive
  portals and non-DoT resolvers still work.
- NetworkManager's periodic **connectivity check** (a call home to detect
  captive portals) disabled.

### Login throttling (`faillock`, on by default)

`pam_faillock` on the `login`, `gdm-password` and `sudo` stacks (wired in by
each service's `logFailures`), tuned by `/etc/security/faillock.conf`: 5
failures → a 15-minute lockout, tracked per user. The LUKS passphrase at the
initrd is a **separate** gate and is unaffected — this only throttles session
and `sudo` logins.

### USBGuard (`usbguard`, off by default)

USBGuard allowlists USB devices attached to a **host** by identity. It's only
meaningful on a device used in USB-**host**/OTG mode. The FP5 runs in
gadget/device mode with no host bus (it presents *itself* to a host and hosts
no peripherals of its own), so USBGuard governs nothing there and no USB
peripheral gating is claimed on the FP5. The option remains for vanilla-mobile
devices that genuinely host USB peripherals. Off by default because it needs a
policy generated from the peripherals you actually use
(`usbguard generate-policy`) — an empty policy blocks everything.
`presentDevicePolicy = "allow"` keeps devices connected at boot working; new
ones must match.

### Duress passphrase (`duress`, off by default)

A second LUKS passphrase entered at the initrd prompt that, instead of
unlocking, runs `cryptsetup luksErase` (destroying every keyslot, so the data
is unrecoverable) and powers the phone off.

**Implementation.** `boot.initrd.systemd.services.duress-check` *owns* the root
unlock. It prompts once via `systemd-ask-password` (so the unl0kr agent renders
the prompt as usual), then:

- tests the entered passphrase against **only** the duress keyslot
  (`cryptsetup open --test-passphrase --key-slot <n>`); on a match it runs
  `cryptsetup luksErase` and powers off;
- otherwise `cryptsetup open`s the device itself, which leaves the mapper
  active so the normal `systemd-cryptsetup@<name>` unit finds it already done;
  a wrong passphrase just re-prompts.

The detect-and-wipe mechanism is validated on a throwaway loopback LUKS (the
duress phrase matches only its slot and triggers the wipe; the real phrase
matches its own slot and never the duress slot, so ordinary unlock is never at
risk). The full initrd integration builds and evaluates, **but its end-to-end
test is destructive by nature** (a successful test wipes the device), so it
ships **off by default** — prove it on a throwaway or fully-backed-up device
before enabling on anything you care about.

To use it:

1. Enroll a dedicated duress passphrase into its own keyslot (default slot 7):

   ```
   sudo cryptsetup luksAddKey --key-slot 7 /dev/disk/by-partlabel/userdata
   ```

2. Point the module at it (`mapperName` must match the device-mapper name the
   initrd opens the root as, i.e. the name in `boot.initrd.luks.devices` /
   disko):

   ```nix
   vanilla-mobile.hardening.duress = {
     enable = true;
     keyslot = 7;
     device = "/dev/disk/by-partlabel/userdata";
     mapperName = "root";
   };
   ```

The wipe fires only when the entered passphrase validates against that slot
(and no other), so the normal unlock passphrase is never at risk.

### Service sandboxing (systemd least-privilege)

The module's own `locked-auto-reboot` service runs with `NoNewPrivileges`,
`RestrictSUIDSGID`, `LockPersonality` and `ProtectHome` — the directives that
harden it without interfering with the reboot path it needs.

The **SoC device daemons** are sandboxed too, with per-daemon profiles in
the qcm6490 module (`daemonHardening` baseline plus `sbxQmi` / `sbxLocked` /
`sbxTee` / `sbxSensor`). `systemd-analyze security`, measured on hardware
(unsandboxed these sit around 8.3 EXPOSED):

| Daemon | Score | Profile |
| --- | --- | --- |
| `neard-poll` | 1.4 | `sbxLocked` (no device/IP/caps) |
| `hexagonrpcd-adsp-sensorspd` | 3.4 | `sbxSensor` |
| `ffsupplicant`, `focal32-load` | 3.7 | `sbxTee` |
| `qbootctl-mark-successful`, `qcom-modem-shutdown` | 3.9 | baseline + `ProtectSystem=strict` |
| `rmtfs`, `tqftpserv`, `msm-modem-uim-selection` | 4.0 | `sbxQmi` |

All subsystems (fingerprint, sensors over D-Bus, modem QMI, audio, NFC) stay
working, with no new failed units. The profiles are tuned per daemon, and the
tuning matters:

- **QMI/QRTR daemons** (`rmtfs`, `tqftpserv`,
  `msm-modem-uim-selection`) restrict address families to
  `AF_UNIX AF_NETLINK AF_QIPCRTR` and deny all IP, with `ProtectSystem=strict`
  (`tqftpserv` keeps `/persist` writable for DSP runtime state).
- **`msm-modem-uim-selection`** needs a capability for its slot-selection QMI
  path (it fails outright with an empty bounding set), so it keeps the default
  caps.
- **`hexagonrpcd`** must **not** get `ProtectSystem` / `PrivateDevices` /
  `RestrictAddressFamilies` (it drives fastrpc devices and talks QRTR); its
  registry is staged by plain file copies in a `+`-prefixed `ExecStartPre`
  (outside the sandbox), so the syscall filter stays at the plain
  `@system-service` set, and it already carries a minimal
  `CAP_DAC_OVERRIDE`-only bounding set.
- **TEE clients** (`ffsupplicant`, `focal32-load`) keep `CAP_SYS_ADMIN` (for
  `/dev/teepriv0`) and leave `MemoryDenyWriteExecute` off (they mmap shared
  buffers for the trusted app); the supplicant also keeps device access for
  the RPMB bsg node.

Tighter still — dropping capabilities on `rmtfs`/`tqftpserv` — is possible but
left off, as too risky for the modem storage path to do without a dedicated
test.

## App sandboxing and the permission model

App confinement on a standard Linux desktop stack, and honest about where it
stops.

- **Wayland gives display isolation for free.** GNOME here runs on Wayland,
  so — unlike X11 — a client cannot read another client's input or scrape its
  windows. Screenshot/screencast is always portal-gated.
- **Flatpak + xdg-desktop-portal is the real, but opt-in, permission model.**
  The FP5 host enables `services.flatpak` and `xdg.portal`. A Flatpak app runs
  in a bubblewrap sandbox with no host filesystem, device or session-bus
  access by default, and reaches files/camera/location/screenshot only through
  portals, with GNOME (this host runs GNOME, not Phosh) drawing the consent
  prompt and remembering the decision. Inspect and tighten with
  `flatpak permissions`, `flatpak override`, and GNOME Settings → Privacy /
  Apps. This is a genuine per-app permission model — for the apps you actually
  install as Flatpaks.

The gaps, stated plainly:

- **Network is not mediated.** Portals do not prompt for network; it is an
  install-time `--share=network` / `--unshare=network` toggle, not a runtime
  per-app grant. There is no runtime per-app network switch here.
- **Native apps stay fully trusted.** Anything not run as a Flatpak — the
  whole native package set — runs as your user with full `$HOME`, bus and
  network access. Confinement is opt-in and bypassable; there is no mandatory,
  unbypassable per-app confinement or per-app UID / SELinux-domain model.
- **SELinux is not a path here.** NixOS has no usable SELinux policy story
  (the `/nix/store` layout is at odds with file-context labeling), so a full
  mandatory-access-control per-app domain model does not exist here; it was
  considered and rejected.

The achievable move is therefore to **shrink the set of apps that "runs as
your user" applies to** by installing third-party/untrusted apps as Flatpaks —
not to close the gap.

## What it cannot do

Being honest about the gap — these are structural, not configurable:

| Capability | Status here |
| --- | --- |
| Verified boot | **Partially achievable on the FP5**: U-Boot enforcing UEFI Secure Boot on signed UKIs is confirmed working (`Secure Boot: enabled (user)`); relocking on a custom AVB root of trust is a further step — see [verified-boot.md](./verified-boot.md). Rollback protection and attestation remain out of reach |
| Hardware attestation | Depends on verified boot internals this platform does not expose |
| Mandatory per-app sandboxing / per-app UID | No SELinux-per-app-domain model on NixOS. **Flatpak + portals** gives a real but *opt-in* per-app permission model for third-party apps (see [App sandboxing](#app-sandboxing-and-the-permission-model)); native apps stay unconfined, and network is not portal-mediated |
| Hardened WebView | Use a browser you trust; `mobile-config-firefox` is packaged here |
| Duress / anti-coercion unlock | A **duress passphrase** is implemented (real systemd-initrd wipe-on-entry, off by default, with a destructive on-device test to run before relying on it, see above); PIN scrambling has no equivalent — lock screens here are PAM (password/fingerprint) |
| Secure-element passphrase rate-limiting (StrongBox/Weaver) | LUKS relies on Argon2 cost, not a secure-element rate limiter; `faillock` throttles session/`sudo` logins but not the LUKS prompt |

The LUKS passphrase at boot is the credential-before-biometrics gate: the
fingerprint stack (focal32) only ever unlocks a running session, never the
disk.
