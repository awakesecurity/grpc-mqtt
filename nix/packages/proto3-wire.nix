{ mkDerivation, base, bytestring, cereal, containers, criterion
, deepseq, doctest, hashable, lib, parameterized, primitive
, QuickCheck, random, safe, tasty, tasty-hunit, tasty-quickcheck
, template-haskell, text, text-short, transformers
, unordered-containers, vector, word-compat
}:
mkDerivation {
  pname = "proto3-wire";
  version = "1.4.3";
  sha256 = "7fa316e7d309bd298ce6f28b85b5bb3d7ec9ce5ada895e2531febedb3f064b3f";
  libraryHaskellDepends = [
    base bytestring cereal containers deepseq hashable parameterized
    primitive QuickCheck safe template-haskell text text-short
    transformers unordered-containers vector word-compat
  ];
  testHaskellDepends = [
    base bytestring cereal doctest QuickCheck tasty tasty-hunit
    tasty-quickcheck text text-short transformers vector
  ];
  benchmarkHaskellDepends = [ base bytestring criterion random ];
  description = "A low-level implementation of the Protocol Buffers (version 3) wire format";
  license = lib.licenses.asl20;
}
