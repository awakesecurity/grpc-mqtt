{-# LANGUAGE ImplicitPrelude #-}

-- | TODO
--
--
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

import Data.ByteString.Lazy qualified as Lazy (ByteString)
import Data.ByteString.Lazy qualified as Lazy.ByteString

import Proto3.Wire.Decode qualified as Decode

---------------------------------------------------------------------------------

import Network.GRPC.HighLevel (MetadataMap)
import Network.GRPC.HighLevel.Extra qualified as Extra

---------------------------------------------------------------------------------
--
-- Tests
--

--
tests :: TestTree
tests =
  testGroup
    "Network.GRPC.HighLevel.Extra"
    [ testProperty "wire-format" tripWireFormat
    ]

-- | Round-trip testing on the encode and decode pair 'encodeMetadataMap'' and
-- 'decodeMetadataMap'
tripWireFormat :: Property
tripWireFormat = property do
  metadata <- forAll Gen.metadataMap
  tripping metadata to from
  where
    to :: MetadataMap -> Lazy.ByteString
    to = Extra.wireEncodeMetadataMap

    from :: Lazy.ByteString -> Either Decode.ParseError MetadataMap
    from = Extra.wireDecodeMetadataMap . Lazy.ByteString.toStrict
