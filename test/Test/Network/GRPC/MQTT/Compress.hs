module Test.Network.GRPC.MQTT.Compress (tests) where

--------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property, withTests, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Compress.Gen qualified as Compress.Gen
import Test.Network.GRPC.MQTT.Option.Gen qualified as Option.Gen

--------------------------------------------------------------------------------

import Data.ByteString qualified as ByteString

import Relude

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Compress qualified as Compress

--------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Compress"
    [ testProperty "Trip.Zstandard" tripCompress
    , testProperty "Compress.Empty" propCompressEmpty
    , testProperty "Decompress.Empty" propDecompressEmpty
    , testProperty "Decompress.Uncompressed" propDecompressUncompressed
    ]

tripCompress :: Property
tripCompress = property do
  -- Generate a pair of ByteStrings:
  --  * 'binary' a ByteString of binary digits. The ByteString is constrained to
  --    binary digits to favor the chance that longer subsequences will be
  --    produced so that compression can have a meaningful effect.
  --  * 'packed' a ByteString not equal to 'binary' that has been compressed by
  --    zstd .
  (binary, packed) <- forAll do
    -- Compress a 1kB-10kB binary ByteString for any compression level. Discard
    -- and regenerate if the ByteString is incompressible.
    clevel <- Option.Gen.clevel
    binary <- Compress.Gen.binary (Range.linear 1_000 10_000)
    let packed :: ByteString
        packed = Compress.compress clevel binary
     in if binary == packed
          then Gen.discard
          else pure (binary, packed)

  -- Assert that decompressing 'packed' should be equal to 'binary' completing
  -- the round-trip.
  Right binary === Compress.decompress packed

-- | Compressing an empty ByteString for any CLevel should result in an empty
-- ByteString.
propCompressEmpty :: Property
propCompressEmpty = withTests 1 $ property do
  clevel <- forAll Option.Gen.clevel
  let packed :: ByteString
      packed = Compress.compress clevel ByteString.empty
   in ByteString.empty === packed

-- | The "zstd" library produces an empty frame error when an empty 'ByteString'
-- is decompressed.
propDecompressEmpty :: Property
propDecompressEmpty = withTests 1 $ property do
  Right ByteString.empty === Compress.decompress ByteString.empty

-- | Decompressing an uncompressed 'ByteString' returns the original
-- 'ByteString'
propDecompressUncompressed :: Property
propDecompressUncompressed = property do
  let range = Range.linear 100 1_000
  bytes <- forAll (Compress.Gen.binary range)
  Right bytes === Compress.decompress bytes
