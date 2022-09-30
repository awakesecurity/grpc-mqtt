{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/21.05";
    flake-utils.url = "github:numtide/flake-utils";
    gitignore = {
      url = "github:hercules-ci/gitignore.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, gitignore }:
    flake-utils.lib.eachSystem ["x86_64-linux" "x86_64-darwin"] (system:
      let
        ghcVersion = "ghc8104";

        haskellOverlay = import nix/overlays/haskell.nix {
          inherit gitignore ghcVersion;
        };

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ haskellOverlay ];
        };
      in {
        packages.default = pkgs.haskell.packages.${ghcVersion}.grpc-mqtt;
        devShells.default = pkgs.grpc-mqtt-dev-shell;
      });
}
