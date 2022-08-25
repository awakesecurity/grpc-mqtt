{ gitignore, ghcVersion }:

final: prev: {
  haskell = prev.haskell // {
      packages = prev.haskell.packages // {
        "${ghcVersion}" = prev.haskell.packages."${ghcVersion}".override {
          overrides = hfinal: hprev: {
            # Package Overrides
            grpc-haskell = final.haskell.lib.dontCheck (hfinal.callPackage ../packages/grpc-haskell.nix { });
            grpc-haskell-core = final.haskell.lib.doJailbreak (hfinal.callPackage ../packages/grpc-haskell-core.nix { 
              gpr = final.grpc;
            });
            net-mqtt = final.haskell.lib.dontCheck (hfinal.callPackage ../packages/net-mqtt.nix { });
            proto3-suite = final.haskell.lib.dontCheck (hfinal.callPackage ../packages/proto3-suite.nix { });
            proto3-wire = hfinal.callPackage ../packages/proto3-wire.nix  { };
            range-set-list = final.haskell.lib.overrideCabal hprev.range-set-list (_: {
              broken = false;
              jailbreak = true;
            });
            word-compat = hfinal.callPackage ../packages/word-compat.nix { };

            grpc-mqtt = (hfinal.callCabal2nix "grpc-mqtt" (gitignore.lib.gitignoreSource ../..) { }).overrideAttrs (old: {
              buildInputs = (old.buildInputs or []) ++ [ final.mosquitto ];
              preCheck = "./scripts/host-mosquitto.sh -d &";
              postCheck = "xargs --arg-file=test-files/mqtt-broker.pid kill";
            });
          };
        };
      };
  };

  grpc-mqtt-devShell =
    let
      hsPkgs = final.haskell.packages.${ghcVersion};
    in
      hsPkgs.shellFor {
        name = "grpc-mqtt";

        buildInputs = [
          final.cabal-install
          final.grpc
          final.haskell-language-server
          final.hlint
          final.mosquitto
          hsPkgs.hp2pretty
          hsPkgs.proto3-suite
          hsPkgs.threadscope
        ];

        src = null;
        packages = pkgs: [pkgs.grpc-mqtt];
      };
}
