{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | TODO
module Test.Network.GRPC.MQTT.Message.Request
  ( -- * Test Tree
    tests,
  )
where

---------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property, tripping)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import Test.Network.GRPC.MQTT.Message.Request.Gen qualified as Gen

---------------------------------------------------------------------------------

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as Lazy (ByteString)
import Data.ByteString.Lazy qualified as Lazy.ByteString

import Network.GRPC.MQTT.Message.Request (Request)
import Network.GRPC.MQTT.Message.Request qualified as Request

import Proto3.Wire.Decode qualified as Decode

---------------------------------------------------------------------------------
--
-- Tests
--

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Message.Request"
    [ testProperty "wire-format" tripWireFormat
    ]

-- | Round-trip test on 'Request' serialization.
tripWireFormat :: Property
tripWireFormat = property do
  payload <- forAll Gen.request
  tripping payload to from
  where
    to :: Request ByteString -> Lazy.ByteString
    to = Request.wireWrapRequest

    from :: Lazy.ByteString -> Either Decode.ParseError (Request ByteString)
    from = Request.wireUnwrapRequest . Lazy.ByteString.toStrict
