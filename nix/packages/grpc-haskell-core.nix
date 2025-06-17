{ mkDerivation, async, base, bytestring, c2hs, clock, containers
, fetchgit, gpr, grpc, lib, managed, pipes, proto3-suite
, QuickCheck, safe, stm, tasty, tasty-hunit, tasty-quickcheck
, template-haskell, text, time, transformers, turtle, unix
}:
mkDerivation {
  pname = "grpc-haskell-core";
  version = "0.6.1";
  src = fetchgit {
    url = "https://github.com/awakesecurity/gRPC-haskell.git";
    sha256 = "1asxvx19armyqbfl19licxg8gd1c7r27vbkr81hymm41jwlnnrk8";
    rev = "f6d68ec04756a6427fd207573f581870f12bae93";
    fetchSubmodules = true;
  };
  postUnpack = "sourceRoot+=/core; echo source root reset to $sourceRoot";
  libraryHaskellDepends = [
    base bytestring clock containers managed stm template-haskell
    transformers
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
