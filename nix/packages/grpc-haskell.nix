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
    sha256 = "0lvv0jyaxrwg6zw8ydabna6rrq2qns1phl5v1z6kmi2pkgyr37rd";
    rev = "f27da0205a774c84dde27b2d0ea306eca25cb710";
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
