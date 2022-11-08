{ mkDerivation, base, containers, fetchgit, generic-deriving, ghc
, large-generics, lib, mtl, newtype, primitive
, record-dot-preprocessor, record-hasfield, syb, tasty, tasty-hunit
, template-haskell, transformers
}:
mkDerivation {
  pname = "large-records";
  version = "0.2.2.0";
  src = fetchgit {
    url = "https://github.com/rkaippully/large-records";
    sha256 = "05s9mjy7sribzmyk8ry78s8dv22sja6l9jb5d4mbmldc9ldjf9b7";
    rev = "b47fd98cf306cbf1292dfd438180215f213ccf4e";
    fetchSubmodules = true;
  };
  postUnpack = "sourceRoot+=/large-records; echo source root reset to $sourceRoot";
  libraryHaskellDepends = [
    base containers ghc large-generics mtl primitive record-hasfield
    syb template-haskell transformers
  ];
  testHaskellDepends = [
    base generic-deriving large-generics mtl newtype
    record-dot-preprocessor record-hasfield tasty tasty-hunit
    template-haskell transformers
  ];
  description = "Efficient compilation for large records, linear in the size of the record";
  license = lib.licenses.bsd3;
}
