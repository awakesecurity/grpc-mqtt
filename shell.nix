{ ghc ? "ghc8104" }:

let
  pkgs = import ./default.nix {
    inherit ghc;
  };

in pkgs.grpc-mqtt.env.overrideAttrs (old: {
  buildInputs = (old.buildAttrs or []) ++ [
    pkgs.cabal-install
    pkgs.grpc
    pkgs.hp2pretty
    pkgs.proto3-suite
    pkgs.mosquitto
    pkgs.threadscope
  ];
})
