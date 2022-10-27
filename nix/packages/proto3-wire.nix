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
    sha256 = "1pyz1llv466q1vz4z7gks1cbxarxkbpf0z818vs5f1s1v4s2w7v6";
    rev = "d310747bf6e08d1d2d7ee4964d88193683da2f05";
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
