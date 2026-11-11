{
  description = "Run standard NixOS on your mobile devices!";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      inherit (nixpkgs) lib;

      # The packages are phone packages, so only aarch64-linux builds them
      systems = [ "aarch64-linux" ];

      getDefault =
        system:
        import ./default.nix {
          flake = self;
          inherit inputs system;
        };

      # Nested package sets become "set/name" attributes, which flake
      # `packages` needs; only sets marked recurseForDerivations are entered
      flatten =
        prefix:
        lib.concatMapAttrs (
          name: value:
          let
            path = prefix ++ [ name ];
          in
          if lib.isDerivation value then
            { ${lib.concatStringsSep "/" path} = value; }
          else if lib.isAttrs value && value.recurseForDerivations or false then
            flatten path value
          else
            { }
        );

      # The modules take the system from the configuration that imports them,
      # so the one given here only fills default.nix's argument
      modules = getDefault (lib.head systems);
    in
    {
      packages = lib.genAttrs systems (system: flatten [ ] (getDefault system).packages);
      inherit (modules) nixosModules homeManagerModules;
    };
}
