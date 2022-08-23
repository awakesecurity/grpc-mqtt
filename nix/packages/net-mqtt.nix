{ mkDerivation, async, attoparsec, attoparsec-binary, base, binary
, bytestring, checkers, conduit, conduit-extra, connection
, containers, deepseq, fetchgit, hpack, HUnit, lib
, network-conduit-tls, network-uri, optparse-applicative
, QuickCheck, stm, tasty, tasty-hunit, tasty-quickcheck, text
, websockets
}:
mkDerivation {
  pname = "net-mqtt";
  version = "0.8.2.2";
  src = fetchgit {
    url = "https://github.com/dustin/mqtt-hs";
    sha256 = "0k57pl6vpnp8966bpng87jj80yqkdfy07z5f8x02y1x3dyvi3373";
    rev = "64c814c36d6a25e3d982873fd4e6fb64e643278b";
    fetchSubmodules = true;
  };
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    async attoparsec attoparsec-binary base binary bytestring conduit
    conduit-extra connection containers deepseq network-conduit-tls
    network-uri QuickCheck stm text websockets
  ];
  libraryToolDepends = [ hpack ];
  executableHaskellDepends = [
    async attoparsec attoparsec-binary base binary bytestring conduit
    conduit-extra connection containers deepseq network-conduit-tls
    network-uri optparse-applicative QuickCheck stm text websockets
  ];
  testHaskellDepends = [
    async attoparsec attoparsec-binary base binary bytestring checkers
    conduit conduit-extra connection containers deepseq HUnit
    network-conduit-tls network-uri QuickCheck stm tasty tasty-hunit
    tasty-quickcheck text websockets
  ];
  prePatch = "hpack";
  homepage = "https://github.com/dustin/mqtt-hs#readme";
  description = "An MQTT Protocol Implementation";
  license = lib.licenses.bsd3;
}
