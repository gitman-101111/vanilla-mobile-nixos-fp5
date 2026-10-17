{
  hexagonrpc,
}:
# nixpkgs' hexagonrpc 0.5.0 already ships the systemd units (upstream commit
# c4109b45), which this used to add with a patch.
hexagonrpc.overrideAttrs (prevAttrs: {
  patches = (prevAttrs.patches or [ ]) ++ [
    # hexagonfs is read-only upstream: every open for write from the DSP is
    # refused with AEE_EUNSUPPORTED. The ADSP sensor process needs to write
    # back its registry (temp.json + rename over the target, and
    # sns_reg_version) under /mnt/vendor/persist/sensors; on this port those
    # writes were denied at ~48/s for the first ~20s of every first attach
    # and the registry write-back has never once succeeded. This implements
    # fopen_with_env "w"/"a", fwrite, fsync, fremove and frename (extension
    # method 33 behind message ID 31), backed by the parent directory's real
    # fd, so only physically-mapped writable directories (the /persist bind
    # mount) accept writes -- the nix store stays read-only at the VFS level.
    ./hexagonfs-write-support.patch
  ];

  postPatch = (prevAttrs.postPatch or "") + ''
    substituteInPlace hexagonrpcd/rpcd.c --replace-fail '/usr/share/qcom' '/run/current-system/sw/share/qcom'
  '';
})
