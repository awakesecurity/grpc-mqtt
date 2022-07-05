{-# LANGUAGE ImportQualifiedPost #-}

module Test.Network.GRPC.MQTT.Message.Request
  ( -- * Test Tree
    tests,
  )
where

---------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property, tripping)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import Test.Network.GRPC.MQTT.Message.Gen qualified as Gen

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Request (Request)
import Network.GRPC.MQTT.Message.Request qualified as Request

import Proto3.Wire.Decode qualified as Decode

import Relude

---------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Message.Request"
    [ testProperty "Wire.Request" tripWireFormat
    ]

-- | Round-trip test on 'Request' serialization.
tripWireFormat :: Property
tripWireFormat = property do
  payload <- forAll Gen.request
  tripping payload to from
  where
    to :: Request ByteString -> LByteString
    to = Request.wireWrapRequest

    from :: LByteString -> Either Decode.ParseError (Request ByteString)
    from = Request.wireUnwrapRequest . toStrict
