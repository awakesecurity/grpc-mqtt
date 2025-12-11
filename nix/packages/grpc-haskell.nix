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
    sha256 = "032157rn88plw7g0f901wh5i6w7hjhlcqfr30cvbcb6xz3wpv91p";
    rev = "2f89b1ae6c27f521983248a95483123bedd89d05";
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
