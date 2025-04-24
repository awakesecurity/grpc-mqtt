{ gitignore, ghc }:

final: prev: {
  haskell = prev.haskell // {
    packages = prev.haskell.packages // {
      "${ghc}" = prev.haskell.packages."${ghc}".override (old: {
        overrides = prev.lib.fold prev.lib.composeExtensions (old.overrides or (_: _: { })) [
          (hfinal: hprev: {
            proto3-wire = final.haskell.lib.dontCheck (hfinal.callPackage ../packages/proto3-wire.nix  { });
            proto3-suite = final.haskell.lib.dontCheck (hfinal.callPackage ../packages/proto3-suite.nix { });
          })
          (hfinal: _: {
            grpc-haskell = final.haskell.lib.doJailbreak
              (final.haskell.lib.dontCheck (hfinal.callPackage ../packages/grpc-haskell.nix { }));
            grpc-haskell-core = final.haskell.lib.doJailbreak
              (final.haskell.lib.dontCheck (hfinal.callPackage ../packages/grpc-haskell-core.nix {
                 gpr = final.grpc;
              }));
          })
          (hfinal: _: {
            grpc-mqtt = (hfinal.callCabal2nix "grpc-mqtt" (gitignore.lib.gitignoreSource ../..) { }).overrideAttrs (old: {
              buildInputs = (old.buildInputs or []) ++ [ final.mosquitto ];

              # The tests require a running mosquitto server
              preCheck = "bash ./scripts/host-mosquitto.sh -d &";
              postCheck = "xargs --arg-file=test-files/mqtt-broker.pid kill";
            });
          })
        ];
      });
    };
  };

  grpc-mqtt-dev-shell =
    let
      hsPkgs = final.haskell.packages.${ghc};
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
        ];

        packages = pkgs: [pkgs.grpc-mqtt];
      };
}
