{ lib, pkgs }:
lib.concatMapAttrs
  (name: value: {
    ${name} = value;
    # Cache kernel config files for <https://github.com/NixOS/nixpkgs/blob/5404c134fd2a119addaf62f1986c3e3816b6dcc5/nixos/modules/config/sysctl.nix#L73>.
    "${name}-configfile" = value.configfile;
  })
  {
    # Pinned to the version its patch series was rebased on.
    linux_sdm845 = pkgs.callPackage ./sdm845 { };
    # Tracks pkgs.linux_latest; see update.yml for the weekly patch/config canary.
    linux_fairphone_fp5 = pkgs.callPackage ./fairphone-fp5 { };
  }
