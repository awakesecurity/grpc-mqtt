{ gitignore, ghc }:

final: prev: {
  haskell = prev.haskell // {
    packages = prev.haskell.packages // {
      "${ghc}" = prev.haskell.packages."${ghc}".override (old: {
        overrides = prev.lib.fold prev.lib.composeExtensions (old.overrides or (_: _: { })) [
          (hfinal: hprev: {
            # Too tight bounds to support GHC 9.10
            # See: https://github.com/dustin/mqtt-hs/issues/52
            net-mqtt = final.haskell.lib.doJailbreak hprev.net-mqtt;

            # GHC 9.12 support
            pqueue = final.haskell.lib.doJailbreak hprev.pqueue;
            optparse-generic = final.haskell.lib.doJailbreak hprev.optparse-generic;
            insert-ordered-containers = final.haskell.lib.doJailbreak hprev.insert-ordered-containers;
            swagger2 = final.haskell.lib.doJailbreak hprev.swagger2;

            proto3-wire = final.haskell.lib.dontCheck (hfinal.callPackage ../packages/proto3-wire.nix  { });
            proto3-suite = final.lib.pipe (hfinal.callPackage ../packages/proto3-suite.nix { }) [
              final.haskell.lib.dontCheck
              final.haskell.lib.doJailbreak
            ];

            grpc-haskell = final.lib.pipe (hfinal.callPackage ../packages/grpc-haskell.nix { }) [
              final.haskell.lib.dontCheck
              final.haskell.lib.doJailbreak
            ];
            grpc-haskell-core = final.lib.pipe (hfinal.callPackage ../packages/grpc-haskell-core.nix { gpr = final.grpc; }) [
              final.haskell.lib.dontCheck
              final.haskell.lib.doJailbreak
              (final.haskell.lib.compose.appendConfigureFlag "--ghc-option=-Wno-deriving-typeable")  # GHC 9.12
              final.haskell.lib.dontHaddock  # TODO: the configure flags ^^ don't propagate to haddocks :(
            ];
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

  grpc-mqtt = final.haskell.packages.${ghc}.grpc-mqtt;

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
