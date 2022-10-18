{ mkDerivation, async, base, bytestring, clock, containers
, criterion, fetchgit, grpc-haskell-core, lib, managed, pipes
, proto3-suite, proto3-wire, QuickCheck, random, safe, tasty
, tasty-hunit, tasty-quickcheck, text, time, transformers, turtle
, unix
}:
mkDerivation {
  pname = "grpc-haskell";
  version = "0.3.0";
  src = fetchgit {
    url = "https://github.com/awakesecurity/gRPC-haskell";
    sha256 = "sha256-/+mNNpOGkOXzh3SX6lV2riXknvLsSdIAIbUWy5kKlmE=";
    rev = "8bb4f062be4e92fca4bf4d5980db56547b4c116b";
    fetchSubmodules = true;
  };
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    async base bytestring grpc-haskell-core managed proto3-suite
    proto3-wire
  ];
  testHaskellDepends = [
    async base bytestring clock containers managed pipes proto3-suite
    QuickCheck safe tasty tasty-hunit tasty-quickcheck text time
    transformers turtle unix
  ];
  benchmarkHaskellDepends = [
    async base bytestring criterion proto3-suite random
  ];
  homepage = "https://github.com/awakenetworks/gRPC-haskell";
  description = "Haskell implementation of gRPC layered on shared C library";
  license = lib.licenses.asl20;
}
