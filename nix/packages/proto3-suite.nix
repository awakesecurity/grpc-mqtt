{ mkDerivation, aeson, aeson-pretty, attoparsec, base
, base64-bytestring, binary, bytestring, cereal, containers
, contravariant, deepseq, doctest, fetchgit, filepath, foldl
, generic-arbitrary, hashable, haskell-src, hedgehog
, insert-ordered-containers, large-generics, large-records, lens
, lib, mtl, neat-interpolation, optparse-applicative
, optparse-generic, parsec, parsers, pretty, pretty-show
, proto3-wire, QuickCheck, quickcheck-instances, range-set-list
, safe, sop-core, split, swagger2, system-filepath, tasty
, tasty-hedgehog, tasty-hunit, tasty-quickcheck, text, time
, transformers, turtle, vector
}:
mkDerivation {
  pname = "proto3-suite";
  version = "0.5.2";
  src = fetchgit {
    url = "https://github.com/rkaippully/proto3-suite";
    sha256 = "0yhdyfz3jnpw1xdvlljcz033xqjli29qiidzcpbwfa8w6xjsqirv";
    rev = "0a06ab1dad01d60da57322ecbe5be226167048c4";
    fetchSubmodules = true;
  };
  isLibrary = true;
  isExecutable = true;
  enableSeparateDataOutput = true;
  libraryHaskellDepends = [
    aeson aeson-pretty attoparsec base base64-bytestring binary
    bytestring cereal containers contravariant deepseq filepath foldl
    hashable haskell-src insert-ordered-containers large-generics
    large-records lens mtl neat-interpolation parsec parsers pretty
    pretty-show proto3-wire QuickCheck quickcheck-instances safe
    sop-core split swagger2 system-filepath text time transformers
    turtle vector
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
    tasty-quickcheck text transformers turtle vector
  ];
  description = "A higher-level API to the proto3-wire library";
  license = lib.licenses.asl20;
}
