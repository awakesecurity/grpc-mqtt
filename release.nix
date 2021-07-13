let
  nixpkgs = builtins.fetchTarball {
    #21.05
    url = "https://github.com/NixOS/nixpkgs/archive/7e9b0dff974c89e070da1ad85713ff3c20b0ca97.tar.gz";
    sha256 = "1ckzhh24mgz6jd1xhfgx0i9mijk6xjqxwsshnvq789xsavrmsc36";
  };

  config = {allowUnfree = true; allowBroken = true;};

  grpc-haskell-src = pkgs.fetchFromGitHub {
    owner  = "awakesecurity";
    repo   = "gRPC-haskell";
    rev    = "e1091b9c0dc9dee8354cf63c9aebe51fa041cfd9";
    sha256 = "0rkmcd0rnhbh4da65477hdsh3j70ma38wi1qq953bb509byhilp8";
  };

  proto-files = ./proto;

  overlay = pkgsNew: pkgsOld: {
    inherit (import "${grpc-haskell-src}/release.nix") grpc;

    haskellPackages = pkgsOld.haskellPackages.override (old: {
      overrides =
        let
          packageSources = pkgsNew.haskell.lib.packageSourceOverrides {
            "grpc-mqtt"    = ./.;
            "grpc-haskell" = "${grpc-haskell-src}";
          };

          manualOverrides = haskellPackagesNew: haskellPackagesOld: {
            range-set-list    = pkgsNew.haskell.lib.doJailbreak haskellPackagesOld.range-set-list;
            proto3-suite      = pkgsNew.haskell.lib.dontCheck haskellPackagesOld.proto3-suite;
            
            grpc-haskell      =  pkgsNew.haskell.lib.dontCheck haskellPackagesOld.grpc-haskell;
            grpc-haskell-core = haskellPackagesNew.callCabal2nix "grpc-haskell-core" "${grpc-haskell-src}/core" {
              inherit (pkgsNew) grpc;
              gpr = null;
            };

            grpc-mqtt = pkgsNew.haskell.lib.overrideCabal haskellPackagesOld.grpc-mqtt (oldAttributes: 
              let
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
              {
                postPatch = (oldAttributes.postPatch or "") + copyGeneratedCode;
                # Network failures?
                doCheck = false;          
              });
          };

          default = old.overrides or (_: _: {});

        in
          pkgsNew.lib.fold pkgsNew.lib.composeExtensions default [
            packageSources
            manualOverrides
          ];
    });
  };

  pkgs = import nixpkgs { inherit config; overlays = [ overlay ]; };

  devTools = with pkgs; [ 
    cabal-install
    grpc
    haskellPackages.c2hs
    haskellPackages.proto3-suite
    haskell-language-server
  ];

in { 
  inherit (pkgs.haskellPackages) grpc-mqtt;

  shell = pkgs.haskellPackages.grpc-mqtt.env.overrideAttrs (oldEnv: {
    nativeBuildInputs = oldEnv.nativeBuildInputs ++ devTools;
  });
}
