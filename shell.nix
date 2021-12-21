{ compiler ? "ghc8104"
}:

let
  pkgs = import ./nix/pkgs.nix {
    inherit compiler;
  };

  grpc-mqtt = pkgs.haskellPackages.grpc-mqtt;

in grpc-mqtt.env.overrideAttrs (old: {
  buildInputs = (old.buildAttrs or []) ++ [
    pkgs.cabal-install
    pkgs.grpc
    pkgs.haskellPackages.c2hs
    pkgs.haskellPackages.proto3-suite
    pkgs.coz
    pkgs.mosquitto
  ];
})
