let 
  pkgs = import nix/pkgs.nix {};
in
  pkgs.haskell.packages."${ghc}".grpc-mqtt