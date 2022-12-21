{ mkDerivation, aeson, aeson-pretty, attoparsec, base
, base64-bytestring, binary, bytestring, cereal, containers
, contravariant, deepseq, dhall, doctest, fetchgit, filepath, foldl
, generic-arbitrary, hashable, haskell-src, hedgehog
, insert-ordered-containers, large-generics, large-records, lens
, lib, mtl, neat-interpolation, optparse-applicative
, optparse-generic, parsec, parsers, pretty, pretty-show
, proto3-wire, QuickCheck, quickcheck-instances, range-set-list
, safe, split, swagger2, system-filepath, tasty, tasty-hedgehog
, tasty-hunit, tasty-quickcheck, text, text-short, time
, transformers, turtle, vector
}:
mkDerivation {
  pname = "proto3-suite";
  version = "0.6.0";
  src = fetchgit {
    url = "https://github.com/awakesecurity/proto3-suite";
    sha256 = "1238yl4zic59ndcgrhjq81bb6kbgi7l4s04sb5a4nyj6giccp8hz";
    rev = "bc360c2bad527a90ae4443c361ac14be7f084bda";
    fetchSubmodules = true;
  };
  isLibrary = true;
  isExecutable = true;
  enableSeparateDataOutput = true;
  libraryHaskellDepends = [
    aeson aeson-pretty attoparsec base base64-bytestring binary
    bytestring cereal containers contravariant deepseq dhall filepath
    foldl hashable haskell-src insert-ordered-containers large-generics
    large-records lens mtl neat-interpolation parsec parsers pretty
    pretty-show proto3-wire QuickCheck quickcheck-instances safe split
    swagger2 system-filepath text text-short time transformers turtle
    vector
  ];
  executableHaskellDepends = [
    base containers mtl optparse-applicative optparse-generic
    proto3-wire range-set-list system-filepath text turtle
  ];
  testHaskellDepends = [
    aeson attoparsec base base64-bytestring bytestring cereal
    containers deepseq doctest generic-arbitrary hedgehog
    large-generics large-records mtl parsec pretty pretty-show
    proto3-wire QuickCheck swagger2 tasty tasty-hedgehog tasty-hunit
    tasty-quickcheck text text-short transformers turtle vector
  ];
  description = "A higher-level API to the proto3-wire library";
  license = lib.licenses.asl20;
}
