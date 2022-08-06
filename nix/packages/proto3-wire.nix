{ mkDerivation, base, bytestring, cereal, containers, criterion
, deepseq, doctest, fetchgit, ghc-prim, hashable, lib
, parameterized, primitive, QuickCheck, random, safe, tasty
, tasty-hunit, tasty-quickcheck, text, transformers
, unordered-containers, vector, word-compat
}:
mkDerivation {
  pname = "proto3-wire";
  version = "1.4.0";
  src = fetchgit {
    url = "https://github.com/awakesecurity/proto3-wire";
    sha256 = "1pr078k7j5yvsixh7g76bfb3w5a5nxsjl9lgvc5ji4nm0ngx5i61";
    rev = "ae24c00c83cbce29750005b1fa6506c1e62e4822";
    fetchSubmodules = true;
  };
  libraryHaskellDepends = [
    base bytestring cereal containers deepseq ghc-prim hashable
    parameterized primitive QuickCheck safe text transformers
    unordered-containers vector word-compat
  ];
  testHaskellDepends = [
    base bytestring cereal doctest QuickCheck tasty tasty-hunit
    tasty-quickcheck text transformers vector
  ];
  benchmarkHaskellDepends = [ base bytestring criterion random ];
  description = "A low-level implementation of the Protocol Buffers (version 3) wire format";
  license = lib.licenses.asl20;
}
