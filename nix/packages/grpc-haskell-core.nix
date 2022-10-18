{ mkDerivation, async, base, bytestring, c2hs, clock, containers
, fetchgit, gpr, grpc, lib, managed, pipes, proto3-suite
, QuickCheck, safe, stm, tasty, tasty-hunit, tasty-quickcheck, text
, time, transformers, turtle, unix
}:
mkDerivation {
  pname = "grpc-haskell-core";
  version = "0.3.0";
  src = fetchgit {
    url = "https://github.com/awakesecurity/gRPC-haskell";
    sha256 = "sha256-/+mNNpOGkOXzh3SX6lV2riXknvLsSdIAIbUWy5kKlmE=";
    rev = "8bb4f062be4e92fca4bf4d5980db56547b4c116b";
    fetchSubmodules = true;
  };
  postUnpack = "sourceRoot+=/core; echo source root reset to $sourceRoot";
  libraryHaskellDepends = [
    base bytestring clock containers managed stm transformers
  ];
  librarySystemDepends = [ gpr grpc ];
  libraryToolDepends = [ c2hs ];
  testHaskellDepends = [
    async base bytestring clock containers managed pipes proto3-suite
    QuickCheck safe tasty tasty-hunit tasty-quickcheck text time
    transformers turtle unix
  ];
  homepage = "https://github.com/awakenetworks/gRPC-haskell";
  description = "Haskell implementation of gRPC layered on shared C library";
  license = lib.licenses.asl20;
}
