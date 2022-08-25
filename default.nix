{ ghc ? "ghc8104" }:

let 
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/refs/tags/21.05.tar.gz";
    sha256 = "1ckzhh24mgz6jd1xhfgx0i9mijk6xjqxwsshnvq789xsavrmsc36";
  };

  overlay = self: super: let 
    gitignoreSource = import nix/packages/gitignoreSource.nix {
      inherit (super) fetchFromGitHub;
    };
  in {
    haskell = super.haskell // {
      packages = super.haskell.packages // {
        "${ghc}" = super.haskell.packages."${ghc}".override (_: {
          overrides = self.lib.composeManyExtensions [
            (haskellPackagesNew: haskellPackagesOld: {
              proto3-suite = self.haskell.lib.dontCheck (haskellPackagesNew.callPackage nix/packages/proto3-suite.nix { });
              proto3-wire = haskellPackagesNew.callPackage nix/packages/proto3-wire.nix  { };
              grpc-haskell-core = haskellPackagesNew.callPackage nix/packages/grpc-haskell-core.nix { 
                gpr = self.grpc;
              };
              grpc-haskell = self.haskell.lib.dontCheck (haskellPackagesNew.callPackage nix/packages/grpc-haskell.nix { });
              net-mqtt = self.haskell.lib.dontCheck (haskellPackagesNew.callPackage nix/packages/net-mqtt.nix { });
              range-set-list = self.haskell.lib.overrideCabal haskellPackagesOld.range-set-list (_: {
                broken = false;
                jailbreak = true;
              });
              word-compat = haskellPackagesNew.callPackage nix/packages/word-compat.nix { };

              grpc-mqtt = (haskellPackagesNew.callCabal2nix "grpc-mqtt" (gitignoreSource ./.) { }).overrideAttrs (old: {
                buildInputs = (old.buildInputs or []) ++ [ self.mosquitto ];
                preCheck = "./scripts/host-mosquitto.sh -d &";
                postCheck = "xargs --arg-file=test-files/mqtt-broker.pid kill";
              });
            })
          ];
        });
      };
    };
  };


  pkgs = import nixpkgs {
    overlays = [ overlay ];
  };
in {
  inherit (pkgs) cabal-install grpc haskell-language-server mosquitto;
  inherit (pkgs.haskell.packages."${ghc}") 
    grpc-mqtt hp2pretty proto3-suite threadscope;
}
