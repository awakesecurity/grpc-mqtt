
module Test.Network.GRPC.HighLevel.Extra
  ( -- * Test Tree
    tests,
  )
where

---------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property, tripping)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import Test.Network.GRPC.HighLevel.Extra.Gen qualified as Gen

---------------------------------------------------------------------------------

import Proto3.Wire.Decode qualified as Decode

import Relude

---------------------------------------------------------------------------------

import Network.GRPC.HighLevel (MetadataMap)
import Network.GRPC.HighLevel.Extra qualified as Extra

---------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.HighLevel.Extra"
    [ testProperty "wire-format" tripWireFormat
    ]

-- | Round-trip testing on 'MetadataMap' wire serialization.
tripWireFormat :: Property
tripWireFormat = property do
  metadata <- forAll Gen.metadataMap
  tripping metadata to from
  where
    to :: MetadataMap -> LByteString
    to = Extra.wireEncodeMetadataMap

    from :: LByteString -> Either Decode.ParseError MetadataMap
    from = Extra.wireDecodeMetadataMap . toStrict
