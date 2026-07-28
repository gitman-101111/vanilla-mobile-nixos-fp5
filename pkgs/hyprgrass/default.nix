{
  hyprgrass,
  wf-touch,
  fetchFromGitHub,
}:
(hyprgrass.override {
  # See <https://github.com/NixOS/nixpkgs/pull/526498>.
  wf-touch = wf-touch.overrideAttrs {
    buildInputs = [ ];
    mesonFlags = [
      "-Dtests=disabled"
    ];
  };
}).overrideAttrs
  (
    finalAttrs: prevAttrs: rec {
      version = "0.56.0";

      src = fetchFromGitHub {
        owner = "horriblename";
        repo = "hyprgrass";
        tag = "hl-${version}";
        hash = "sha256-r0kKcEid5NcolUgfE7rI1TT3VAMxrnjqzGLIVs/lbI8=";
      };
    }
  )
