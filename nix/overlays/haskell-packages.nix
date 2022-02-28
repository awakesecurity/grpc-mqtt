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
  all-cabal-hashes = pkgsOld.fetchurl {
    url = "https://github.com/commercialhaskell/all-cabal-hashes/archive/946958a82b6c589393f3ba9234345ac3f2d3d512.tar.gz";
    sha256 = "00d296y7lxsfplbrhcyr7wp8cymh7zhf0q59ia1kxrly40v47fkr";
  };

  haskellPackages = pkgsOld.haskell.packages."${compiler}".override (old: {
    overrides = pkgsNew.lib.composeManyExtensions [
      (haskellPackagesNew: haskellPackagesOld: {
        proto3-suite = pkgsNew.haskell.lib.dontCheck (haskellPackagesNew.callPackage ../packages/proto3-suite.nix {});
        proto3-wire  = haskellPackagesNew.callPackage ../packages/proto3-wire.nix  {};
        grpc-haskell = pkgsNew.haskell.lib.dontCheck (haskellPackagesNew.callPackage ../packages/grpc-haskell.nix {});
      })
      (haskellPackagesNew: haskellPackagesOld: {
        net-mqtt = haskellPackagesNew.callHackage "net-mqtt" "0.8.1.0" {};

        range-set-list =
          pkgsNew.haskell.lib.overrideCabal
            haskellPackagesOld.range-set-list
            (_: {
              broken = false;
              jailbreak = true;
            });

        grpc-haskell-core =
          let
            source = pkgsNew.fetchFromGitHub {
              owner  = "awakesecurity";
              repo   = "gRPC-haskell";
              rev = "112777023f475ddd752c954056e679fbca0baa44";
              sha256 = "05s3p5xidfdqh3vghday62pscl968vx9r3xmqhs037a8ark3gr6h";
            };
          in haskellPackagesNew.callCabal2nix "grpc-haskell-core" "${source}/core" {
            inherit (pkgsNew) grpc;
            gpr = null;
          };

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
      })];
    });
}
