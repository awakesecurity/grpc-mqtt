{ mkDerivation, base, bytestring, cereal, containers, criterion
, deepseq, doctest, ghc-prim, hashable, lib, parameterized
, primitive, QuickCheck, random, safe, tasty, tasty-hunit
, tasty-quickcheck, template-haskell, text, text-short
, transformers, unordered-containers, vector, word-compat
}:
mkDerivation {
  pname = "proto3-wire";
  version = "1.4.1";
  sha256 = "c5108b8d792b9327903b0086c5ef19bf16266e8b803b9b4e5320f8d42d163e52";
  libraryHaskellDepends = [
    base bytestring cereal containers deepseq ghc-prim hashable
    parameterized primitive QuickCheck safe template-haskell text
    text-short transformers unordered-containers vector word-compat
  ];
  testHaskellDepends = [
    base bytestring cereal doctest QuickCheck tasty tasty-hunit
    tasty-quickcheck text text-short transformers vector
  ];
  benchmarkHaskellDepends = [ base bytestring criterion random ];
  description = "A low-level implementation of the Protocol Buffers (version 3) wire format";
  license = lib.licenses.asl20;
}
