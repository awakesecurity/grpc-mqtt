{ compiler }:

pkgsNew: pkgsOld:

let
  gitignoreSource =
    let
      source = pkgsNew.fetchFromGitHub {
        owner = "hercules-ci";
        repo = "gitignore.nix";
        rev = "211907489e9f198594c0eb0ca9256a1949c9d412";
        sha256 = "06j7wpvj54khw0z10fjyi31kpafkr6hi1k0di13k1xp8kywvfyx8";
      };
    in (import source { inherit (pkgsNew) lib; }).gitignoreSource;

  proto-files = ../../proto;

in {
  haskellPackages = pkgsOld.haskell.packages."${compiler}".override (old: {
    overrides = pkgsNew.lib.composeExtensions
      (old.overrides or (_: _: { }))
      (haskellPackagesNew: haskellPackagesOld: {
        range-set-list =
          pkgsNew.haskell.lib.overrideCabal
            haskellPackagesOld.range-set-list
            (_: {
              broken = false;
              jailbreak = true;
            });

        proto3-suite = pkgsNew.haskell.lib.dontCheck haskellPackagesOld.proto3-suite;

        grpc-haskell-core =
          let
            source = pkgsNew.fetchFromGitHub {
              owner  = "awakesecurity";
              repo   = "gRPC-haskell";
              rev    = "e1091b9c0dc9dee8354cf63c9aebe51fa041cfd9";
              sha256 = "0rkmcd0rnhbh4da65477hdsh3j70ma38wi1qq953bb509byhilp8";
            };
          in haskellPackagesNew.callCabal2nix "grpc-haskell-core" "${source}/core" {
            inherit (pkgsNew) grpc;
            gpr = null;
          };

        grpc-haskell = pkgsNew.haskell.lib.dontCheck haskellPackagesOld.grpc-haskell;

        spectacle =
          let
            source = pkgsNew.fetchFromGitHub {
              owner  = "awakesecurity";
              repo   = "spectacle";
              rev    = "24aeb669d48c3cba92594285fd1031f7ef2ae62f";
              sha256 = "0sn0h70dsk7z0989sdrbjj896hkg42v152cchgrc8798rfjc04p1";
            };
          in haskellPackagesNew.callCabal2nix "spectacle" "${source}" { };

        grpc-mqtt =
          let
            grpc-mqtt-base =
              haskellPackagesNew.callCabal2nix
                "grpc-mqtt"
                (gitignoreSource ../../.)
                { };

            compiled-protos = pkgsNew.runCommand "grpc-mqtt-compile-protos" { } ''
              mkdir -p $out/proto
              cp -r ${proto-files}/. $out/proto/.
              cd $out
              ${haskellPackagesNew.proto3-suite}/bin/compile-proto-file --proto proto/mqtt.proto --out $out
              ${haskellPackagesNew.proto3-suite}/bin/compile-proto-file --proto proto/test.proto --out $out
            '';

            copyGeneratedCode = ''
              mkdir -p gen
              ${pkgsNew.rsync}/bin/rsync \
              --recursive \
              --checksum \
              ${compiled-protos}/ gen
            '';

          in
            pkgsNew.haskell.lib.overrideCabal
              grpc-mqtt-base
              (old: {
                postPatch = (old.postPatch or "") + copyGeneratedCode;

                # Network failures?
                doCheck = false;
              });
      });
  });
}
