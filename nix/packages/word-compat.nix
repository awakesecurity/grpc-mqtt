{ mkDerivation, base, ghc-prim, lib }:
mkDerivation {
  pname = "word-compat";
  version = "0.0.2";
  sha256 = "36e5a1a17f20935f55bf274fb52cbb028d301fd48d814f574d3171ccc6bc9f98";
  libraryHaskellDepends = [ base ghc-prim ];
  description = "Compatibility shim for the Int/Word internal change in GHC 9.2";
  license = lib.licenses.bsd3;
}