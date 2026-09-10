# Built from marcusramberg/fp5-fingerprint-tools rather than vendored here, so
# fixes to the tools land upstream and flow back by bumping the pin.
{
  lib,
  stdenv,
  fetchFromGitHub,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "ftharness";
  version = "0.1.0-unstable-2026-09-01";

  src = fetchFromGitHub {
    owner = "marcusramberg";
    repo = "fp5-fingerprint-tools";
    rev = "d9320448e575c2e219b1100655d0465b09f58d92";
    hash = "sha256-JWwvcnRp+bX3d6qdvM82p4E3O9UNTfZ89xUk89Qu/Yg=";
  };

  sourceRoot = "${finalAttrs.src.name}/ftharness";

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -o ftharness ftharness.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ftharness $out/bin/ftharness
    runHook postInstall
  '';

  meta = {
    description = "Bring-up client for the Fairphone 5 focal32 fingerprint trusted application";
    longDescription = ''
      Loads the FocalTech FT9362 trusted application ("focal32") through the
      QSEECOM TEE driver and runs the init sequence the vendor HAL runs, so
      that the kernel side can be verified before any fingerprint stack
      exists. Needs root: the application is loaded through /dev/teepriv0,
      which requires CAP_SYS_ADMIN.
    '';
    homepage = "https://github.com/marcusramberg/fp5-fingerprint-tools";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
    mainProgram = "ftharness";
  };
})
