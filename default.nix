{ compiler ? "ghc8104"
}:

let
  pkgs = import ./nix/pkgs.nix {
    inherit compiler;
  };

in {
  grpc-mqtt = pkgs.haskellPackages.grpc-mqtt;
}
