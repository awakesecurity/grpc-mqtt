{ mkDerivation, aeson, base, deepseq, fetchgit, generic-deriving
, generics-sop, lib, microlens, mtl, primitive, QuickCheck
, sop-core, tasty, tasty-hunit, tasty-quickcheck
}:
mkDerivation {
  pname = "large-generics";
  version = "0.2.0.0";
  src = fetchgit {
    url = "https://github.com/rkaippully/large-records";
    sha256 = "05s9mjy7sribzmyk8ry78s8dv22sja6l9jb5d4mbmldc9ldjf9b7";
    rev = "b47fd98cf306cbf1292dfd438180215f213ccf4e";
    fetchSubmodules = true;
  };
  postUnpack = "sourceRoot+=/large-generics; echo source root reset to $sourceRoot";
  libraryHaskellDepends = [
    aeson base deepseq generics-sop primitive sop-core
  ];
  testHaskellDepends = [
    aeson base generic-deriving generics-sop microlens mtl QuickCheck
    sop-core tasty tasty-hunit tasty-quickcheck
  ];
  description = "Generic programming API for large-records and large-anon";
  license = lib.licenses.bsd3;
}
