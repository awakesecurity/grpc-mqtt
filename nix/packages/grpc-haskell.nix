{ mkDerivation, async, base, bytestring, clock, containers
, criterion, fetchgit, grpc-haskell-core, lib, managed, pipes
, proto3-suite, proto3-wire, QuickCheck, random, safe, tasty
, tasty-hunit, tasty-quickcheck, text, time, transformers, turtle
, unix
}:
mkDerivation {
  pname = "grpc-haskell";
  version = "0.4.0";
  src = fetchgit {
    url = "https://github.com/awakesecurity/gRPC-haskell.git";
    sha256 = "1ix9lj4fj3qwq3yd91nlkbvkw26h4l32cmhh0887lkh76gv51akq";
    rev = "e5d065bc2a2c14e2c48a9132ba1203b8ad3b073c";
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
