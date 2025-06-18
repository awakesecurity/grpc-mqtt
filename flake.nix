{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/25.05";
    flake-utils.url = "github:numtide/flake-utils";
    gitignore = {
      url = "github:hercules-ci/gitignore.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, gitignore }:
    flake-utils.lib.eachSystem ["x86_64-linux" "x86_64-darwin"] (system:
      let
        haskellOverlay = ghc: import nix/overlays/haskell.nix {
          inherit gitignore ghc;
        };

        ghcVersions = rec {
          default = with-ghc96;

          with-ghc96 = import nixpkgs {
            inherit system;
            overlays = [ (haskellOverlay "ghc96") ];
          };

          with-ghc98 = import nixpkgs {
            inherit system;
            overlays = [ (haskellOverlay "ghc98") ];
          };
        };
      in {
        packages = builtins.mapAttrs (_: pkgs: pkgs.grpc-mqtt) ghcVersions;
        devShells = builtins.mapAttrs (_: pkgs: pkgs.grpc-mqtt-dev-shell) ghcVersions;
      });
}
