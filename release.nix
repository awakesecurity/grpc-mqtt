let 
  pkgs = import ./default.nix {};
in
  pkgs.haskell.packages."${ghc}".grpc-mqtt