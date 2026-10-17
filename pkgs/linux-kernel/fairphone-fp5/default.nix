# Kernel for the Fairphone 5 (qcm6490): mainline plus the board bits that are
# not upstream.
#
# Mainline already has the SoC support, every audio driver the phone needs
# (aw88261, wcd938x, lpass rx/tx macros) and the front camera. Missing are the
# board audio wiring, the rear camera wiring and the imx858 driver, all taken
# from <https://github.com/sc7280-mainline/linux> and carried in
# ./fairphone-fp5-board-support.patch.
#
# The patch has to go through kernelPatches rather than postPatch: the kernel
# config is built by a separate derivation that inherits `patches` but takes
# its postPatch from build.nix, so a postPatch here is silently dropped and
# the Kconfig entry never exists when the config is generated.
#
# The base is pkgs.linux_latest, so a nixpkgs bump that moves linux_latest to
# a new major moves this kernel with it. The patches below are validated on
# the release pinned in flake.lock; when the base moves, the update
# workflow's canary (.github/.forgejo workflows/update.yml) applies them in
# order and generates the config on the new source, so a patch that no
# longer applies — or one that has landed upstream and now applies reversed
# — shows up there before anything is built. Either way it fails the build
# at the configfile step.
#
# How to update:
# - Regenerate the patch with ./update-board-patch.sh against a newer tree.
# - The .dtsi files inside it are label-referenced, so unrelated churn does not
#   break them; dtc fails the build if a referenced label disappears.
# - Drop any patch that has landed upstream in the new base.
{
  lib,
  linux_latest,
  stdenv,
  ...
}:
let
  kernel = linux_latest;
in
kernel.override {
  argsOverride = {
    version = "${kernel.version}-fp5";
    inherit (kernel) modDirVersion;

    extraMeta = {
      description = "Linux kernel for the Fairphone 5";
      platforms = [ "aarch64-linux" ];
    };
  };

  kernelPatches = [
    {
      name = "fairphone-fp5-board-support";
      patch = ./fairphone-fp5-board-support.patch;
    }
    # Without this the device intermittently boots to a black screen: the
    # PTN36502 redriver fails its i2c probe when it runs after the regulator
    # core has powered its rail down, and the DP controller it blocks is a
    # required component of the DPU aggregate, so the internal panel never
    # lights. Kept separate from the board-support patch above because that
    # one is regenerated wholesale by ./update-board-patch.sh.
    {
      name = "ptn36502-redriver-startup-delay";
      patch = ./ptn36502-redriver-startup-delay.patch;
    }
    # WCN6750 sends the baudrate-change command complete event
    # asynchronously; hci_qca mistakes it for the response to a later command
    # and the controller never finishes registering:
    #
    #   Bluetooth: hci0: unexpected event for opcode 0xfc48
    #
    # Not upstream; drop once a bump makes this patch apply reversed.
    {
      name = "hci-qca-drop-unused-event";
      patch = ./hci-qca-drop-unused-event.patch;
    }
    # AFE clock voting: the LPASS core hw-vote response carries a bare u32,
    # not an aprv2_ibasic_rsp_result_t, so q6afe misread it and the aw88261
    # amps never left "device start failed" (no speaker sound). The aw88261
    # driver fixes that used to ride along here landed upstream in 7.2; the
    # q6afe hunk is not upstream.
    {
      name = "q6afe-lpass-core-vote-response";
      patch = ./q6afe-lpass-core-vote-response.patch;
    }
    # NFC. The chip is on i2c9 at 0x08 (mainline's "@ 28" comment copies a
    # sloppy downstream node name; the downstream reg and a live probe both
    # say 0x08), reset on gpio38, IRQ on gpio41, and it speaks raw NCI 2.0
    # over I2C -- no NDLC framing -- so the existing st-nci driver cannot
    # attach. Adds a small raw-NCI driver modeled on nxp-nci plus the DT
    # node. Candidate for upstreaming.
    {
      name = "st21nfcd-nfc-driver";
      patch = ./st21nfcd-nfc-driver.patch;
    }
    # Fingerprint. The FP5's FocalTech sensor sits on an SPI bus that belongs
    # to the secure world (verified: TLMM gpio-reserved-ranges reserves the
    # SE6 pins 56-59), so imaging and matching happen inside a signed
    # TrustZone application ("focal32"). The normal world's job is to load and
    # talk to that application over the QSEECOM command interface. Mainline
    # already carries the QSEECOM SCM glue (qcom_qseecom.c) and the allowlist;
    # these patches add the QSEECOM *TEE* driver that exposes trusted apps
    # through /dev/tee*, plus the misc driver that owns the sensor's reset/
    # power/irq GPIOs and the DT node. Imported from
    # github.com/marcusramberg/nixos-fairphone-fp5.
    {
      name = "qcom-scm-qseecom-fp5-allowlist";
      patch = ./qcom-scm-qseecom-fp5-allowlist.patch;
    }
    {
      name = "tee-qseecom-driver";
      patch = ./tee-qseecom-driver.patch;
    }
    {
      name = "tee-qseecom-align-response";
      patch = ./tee-qseecom-align-response.patch;
    }
    {
      name = "tee-qseecom-request-writeback";
      patch = ./tee-qseecom-request-writeback.patch;
    }
    {
      name = "misc-focaltech-fp-driver";
      patch = ./misc-focaltech-fp-driver.patch;
    }
    {
      name = "dts-fp5-fingerprint-sensor";
      patch = ./dts-fp5-fingerprint-sensor.patch;
    }
    # ADSP audio PD boot race (found 2026-10-19). On roughly a third of cold
    # boots the ADSP's audio protection domain never registers: no APR
    # services, no sound card, no battery reporting. Cause, on the host
    # side: qcom_glink_create_ept() sends the OPEN_ACK for the ADSP's
    # IPCRTR channel before the endpoint callback is installed and before
    # qrtr_smd's probe has registered the QRTR endpoint; the ADSP sends its
    # single HELLO the instant it sees OPEN_ACK, and a packet arriving in
    # that window is silently dropped (glink drops data with no callback,
    # and ignores the -EAGAIN qrtr_smd returns before probe). The ADSP then
    # waits for a HELLO from us, which this kernel never sends, so the
    # whole QRTR handshake (name service, PD mapper, PDR) never happens for
    # that DSP. Re-opening the channel or restarting the ADSP redoes the
    # handshake, which is why those "healed" it.
    #
    # Upstream fix, in 7.3: the host sends its own HELLO once the endpoint
    # is registered (with retry), so the DSP's reply always lands on a ready
    # endpoint and the order no longer matters. Backported verbatim from
    # 544d85de4dc2 ("net: qrtr: Send HELLO message on endpoint register"),
    # and applied only below 7.3, where it is already in the tree.
  ]
  ++ lib.optional (lib.versionOlder kernel.version "7.3") {
    name = "qrtr-send-hello-on-endpoint-register";
    patch = ./qrtr-send-hello-on-endpoint-register.patch;
  }
  ++ [
    # Verified 2026-10-19: 6 of 6 cold boots good on the backport (1 in 3
    # were bad before), each trace showing the ADSP answering our HELLO. The
    # per-packet QRTR trace used to find this (qrtr.debug_node=N, a 10-hunk
    # patch to af_qrtr.c/ns.c/qcom_pd_mapper.c) is kept in
    # ~/Development/fp5-next-patches/ rather than here, so it costs nothing
    # on the shipped kernel.
    # Tried and dropped (2026-10-17): restoring 7.1's fixed ADSP FastRPC remote
    # heap carveout in place of the shared-dma-pool kodiak.dtsi has since 7.2.
    # It silenced the ~5/s "Handover signaled, but it already happened" storm,
    # but upstream added the pool "for audio PD dynamic loading", and on the
    # boot tested the ADSP audio PD never came up (no APR services, no sound
    # card). Inconclusive, since the audio PD also fails to start on some
    # boots without it.
  ];

  # Remove some mostly raspberry pi specific stuff.
  stdenv = lib.recursiveUpdate stdenv {
    hostPlatform.linux-kernel.extraConfig = "";
  };

  structuredExtraConfig = (with lib.kernel; {
    # Rear camera, from the out-of-tree driver in the patch above.
    VIDEO_IMX858 = module;

    # Rear camera focus. The actuator node's "dongwoon,dw9800k" is matched
    # by the dw9719 driver (mainline has carried the DW9800K variant since
    # before 7.1.5); the driver was simply never enabled, which is why the
    # lens never bound and focus stayed fixed.
    VIDEO_DW9719 = module;

    # Board audio. These drivers are all already in mainline.
    SND_SOC_AW88261 = module;
    SND_SOC_WCD938X_SDW = module;
    SND_SOC_LPASS_RX_MACRO = module;
    SND_SOC_LPASS_TX_MACRO = module;
    SND_SOC_LPASS_VA_MACRO = module;
    SND_SOC_QCOM_COMMON = module;
    SND_SOC_SC7280 = module;
    SOUNDWIRE_QCOM = module;

    # NFC: the NCI core plus the raw-NCI ST21NFCD driver added by the patch
    # above.
    NFC = module;
    NFC_NCI = module;
    NFC_ST21NFCD_I2C = module;

    # Fingerprint: the TEE core, the QSEECOM SCM interface and mdt loader it
    # builds on, the QSEECOM TEE driver that loads the focal32 trusted
    # application, and the misc driver owning the sensor's GPIOs.
    TEE = module;
    QCOM_QSEECOM = yes;
    QCOM_MDT_LOADER = yes;
    TEE_QSEECOM = module;
    MISC_FOCALTECH_FP = module;

    # Wanted by the NixOS LUKS module.
    DM_CRYPT = module;
    CRYPTO_CRYPTD = module;
    CRYPTO_USER_API_SKCIPHER = module;
    CRYPTO_LRW = module;

    # In-kernel PD mapper (the port's only mapper), built in rather than =m:
    # as a module its autoload races DSP autoboot, and a DSP whose
    # service-registry lookup misses it registers no service PDs all boot (no
    # audio, battery reporting, Wi-Fi adapter or sensor data). QRTR/QMI/PDR
    # are its Kconfig dependencies.
    QRTR = lib.mkForce yes;
    QCOM_QMI_HELPERS = lib.mkForce yes;
    QCOM_PDR_MSG = lib.mkForce yes;
    QCOM_PD_MAPPER = lib.mkForce yes;
  })
  # --- Hardening (KSPP-recommended), see docs/hardening.md ----------------
  # Compile-time counterparts to the runtime hardening in the
  # vanilla-mobile.hardening module. Kept here because this kernel is
  # custom-built, which is exactly where these belong. mkForce'd as a group:
  # nixpkgs' common-config.nix pins several of these (e.g. MODULE_SIG=n), so
  # each needs to win over that baseline; a force to the same value is a
  # no-op.
  // lib.mapAttrs (lib.const lib.mkForce) (with lib.kernel; {
    # Self-protection: fortified string ops, strong stack protector, full
    # KASLR (base + module region), heap/page-allocator randomisation, and
    # zero-on-alloc/free compiled on by default (not just via cmdline).
    FORTIFY_SOURCE = yes;
    STACKPROTECTOR = yes;
    STACKPROTECTOR_STRONG = yes;
    RANDOMIZE_BASE = yes;
    RANDOMIZE_MODULE_REGION_FULL = yes;
    SLAB_FREELIST_RANDOM = yes;
    SLAB_FREELIST_HARDENED = yes;
    SHUFFLE_PAGE_ALLOCATOR = yes;
    INIT_ON_ALLOC_DEFAULT_ON = yes;
    INIT_ON_FREE_DEFAULT_ON = yes;

    # Read-only kernel/module text and data; panic rather than continue on
    # detected memory corruption; bounds-check copies to/from userspace;
    # catch stack overruns.
    STRICT_KERNEL_RWX = yes;
    STRICT_MODULE_RWX = yes;
    DEBUG_WX = yes;
    BUG_ON_DATA_CORRUPTION = yes;
    HARDENED_USERCOPY = yes;
    SCHED_STACK_END_CHECK = yes;
    VMAP_STACK = yes;

    # Close classic kernel-memory disclosure/patch surfaces. nixpkgs already
    # sets STRICT_DEVMEM/IO_STRICT_DEVMEM (restricting /dev/mem to non-RAM);
    # lockdown below blocks it entirely, so /dev/mem is not removed outright
    # here (that would collide with those baseline options). PROC_KCORE and
    # legacy PTYs are dropped as unneeded disclosure/attack surface.
    PROC_KCORE = no;
    LEGACY_PTYS = no;
    SECURITY_DMESG_RESTRICT = yes;

    # Module signing: every in-tree module is signed with a build-time key
    # (MODULE_SIG_ALL) and unsigned modules are refused (MODULE_SIG_FORCE),
    # covering modules loaded from the mutable rootfs that the signed UKI does
    # not already cover.
    MODULE_SIG = yes;
    MODULE_SIG_ALL = yes;
    MODULE_SIG_FORCE = yes;
    MODULE_SIG_SHA512 = yes;

    # Lockdown LSM in confidentiality mode, forced on from early boot: blocks
    # even root from reading kernel memory, loading unsigned modules and kexec.
    # The lsm= cmdline must list "lockdown" for it to initialise (set in the
    # hardening module's kernelParams).
    SECURITY_LOCKDOWN_LSM = yes;
    SECURITY_LOCKDOWN_LSM_EARLY = yes;
    LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY = yes;
  })
  # --- Only hardware a qcm6490 phone can have ------------------------------
  # nixpkgs' aarch64 baseline is arm64 defconfig: every SoC family enabled
  # and every driver built as a module (7.8k modules shipped, ~220 loaded).
  # Each ARCH_* pulls in that vendor's clock, pinctrl, phy, display, ...
  # drivers, so turning the families off drops them wholesale: a much
  # shorter build and a smaller signed module tree. Generic subsystems the
  # phone uses (USB, Bluetooth, mac80211/ath11k, V4L2, ASoC, ...) and
  # USB-attached device classes are untouched. Expressed as Kconfig options
  # so it carries to newer kernels unchanged; a family that is renamed or
  # dropped upstream shows up as "unused option" at the configfile step.
  // lib.genAttrs (map (a: "ARCH_${a}") [
    "ACTIONS" "AIROHA" "ALPINE" "APPLE" "ASPEED" "AXIADO" "BCM" "BERLIN"
    "BLAIZE" "BST" "CIX" "EXYNOS" "HISI" "INTEL_SOCFPGA" "K3" "KEEMBAY"
    "LG1K" "MA35" "MEDIATEK" "MESON" "MICROCHIP" "MVEBU" "NPCM" "NXP"
    "REALTEK" "RENESAS" "ROCKCHIP" "SEATTLE" "SOPHGO" "SPRD" "STM32" "SUNXI"
    "SYNQUACER" "TEGRA" "THUNDER" "THUNDER2" "UNIPHIER" "VEXPRESS" "VISCONTI"
    "XGENE" "ZYNQMP"
  ]) (lib.const lib.kernel.no)
  // (with lib.kernel; {
    # Board options nixpkgs' common-config forces on for SoC families that
    # are off above: they no longer exist in this config, so mark them
    # optional rather than letting the generator fail on them.
    DRM_VC4_HDMI_CEC = lib.mkForce (option no); # BCM2835
    FSL_MC_UAPI_SUPPORT = lib.mkForce (option no); # NXP Layerscape
    MT798X_WMAC = lib.mkForce (option no); # MediaTek
    NET_VENDOR_MEDIATEK = lib.mkForce (option no); # MediaTek
    ROCKCHIP_DW_HDMI_QP = lib.mkForce (option no); # Rockchip
    ROCKCHIP_DW_MIPI_DSI2 = lib.mkForce (option no); # Rockchip
    SUN8I_DE2_CCU = lib.mkForce (option no); # Allwinner
    USB_XHCI_TEGRA = lib.mkForce (option no); # Tegra

    # Hardware classes that cannot be attached to this board (no PCIe
    # slots): desktop GPUs, PCI capture cards, RDMA, PCI SCSI HBAs. UFS
    # lives outside SCSI_LOWLEVEL and stays. Each cut below is paired with
    # the sub-options nixpkgs' common-config sets under it, which cease to
    # exist once the parent is off; a nixpkgs bump that adds another one
    # shows up as "unused option" at the configfile step. Cuts whose
    # collateral is larger than their gain (PCI sound: five overrides for
    # ~250 objects) are deliberately not made.
    DRM_AMDGPU = no;
    DRM_AMDGPU_SI = lib.mkForce (option no);
    DRM_AMDGPU_CIK = lib.mkForce (option no);
    DRM_AMDGPU_USERPTR = lib.mkForce (option no);
    DRM_AMD_ACP = lib.mkForce (option no);
    DRM_AMD_DC_FP = lib.mkForce (option no);
    DRM_AMD_DC_SI = lib.mkForce (option no);
    DRM_AMD_ISP = lib.mkForce (option no);
    DRM_AMD_SECURE_DISPLAY = lib.mkForce (option no);
    HSA_AMD = lib.mkForce (option no);
    HSA_AMD_P2P = lib.mkForce (option no);
    DRM_AST = no;
    DRM_MGAG200 = no;
    DRM_NOUVEAU = no;
    DRM_NOUVEAU_SVM = lib.mkForce (option no);
    DRM_RADEON = no;
    DRM_VMWGFX = no;
    DRM_XE = no;
    MEDIA_PCI_SUPPORT = lib.mkForce no;
    INFINIBAND = lib.mkForce no;
    INFINIBAND_IPOIB = lib.mkForce (option no);
    INFINIBAND_IPOIB_CM = lib.mkForce (option no);
    SCSI_LOWLEVEL = lib.mkForce no;
    SCSI_LOWLEVEL_PCMCIA = lib.mkForce (option no);
    AIC79XX_DEBUG_ENABLE = lib.mkForce (option no);
    AIC7XXX_DEBUG_ENABLE = lib.mkForce (option no);
    AIC94XX_DEBUG = lib.mkForce (option no);
    MEGARAID_NEWGEN = lib.mkForce (option no);
    FUSION = lib.mkForce no;
  });
}
