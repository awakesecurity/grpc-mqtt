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
    sha256 = "1kpz9ndihn9905c20g106lghx7i7kl8lc4fqhh8cybvgrxl24yrg";
    rev = "5a946d2a5eeecd0d17265181503669d40d61629e";
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
