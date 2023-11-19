{ gitignore, ghc }:

final: prev: {
  haskell = prev.haskell // {
    packages = prev.haskell.packages // {
      "${ghc}" = prev.haskell.packages."${ghc}".override (old: {
        overrides = prev.lib.fold prev.lib.composeExtensions (old.overrides or (_: _: { })) [
          (hfinal: hprev: {
            # Support text v2 if using GHC 9.4+; otherwise
            # use an older version that works with GHC 8.10.7.
            chell =
              if builtins.compareVersions hfinal.ghc.version "9.4" < 0
                then hprev.chell
                else final.haskell.lib.doJailbreak (hfinal.callPackage ../packages/chell.nix { });

            # The tests in data-diverse do not build with GHC 9.4.
            data-diverse = final.haskell.lib.dontCheck hprev.data-diverse;

            # Needed by threadscope-0.2.14.1.
            ghc-events = hfinal.callPackage ../packages/ghc-events.nix { };

            # Support GHC 9.4.
            record-dot-preprocessor = hfinal.callPackage ../packages/record-dot-preprocessor.nix { };
          })
          (hfinal: hprev: {
            net-mqtt = final.haskell.lib.dontCheck (hfinal.callPackage ../packages/net-mqtt.nix { });
          })
          (hfinal: hprev: {
            proto3-wire = final.haskell.lib.dontCheck (hfinal.callPackage ../packages/proto3-wire.nix  { });
            proto3-suite = final.haskell.lib.dontCheck (hfinal.callPackage ../packages/proto3-suite.nix { });

            range-set-list = final.haskell.lib.overrideCabal hprev.range-set-list (_: {
              broken = false;
              jailbreak = true;
            });

            word-compat = final.haskell.lib.dontCheck (hfinal.callPackage ../packages/word-compat.nix { });
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
        ] ++ (
          # threadscope does not yet support template-haskell-2.19, the version for ghc 9.4
          if builtins.compareVersions hsPkgs.ghc.version "9.4" < 0
            then [hsPkgs.threadscope]
            else []
        );

        packages = pkgs: [pkgs.grpc-mqtt];
      };
}
