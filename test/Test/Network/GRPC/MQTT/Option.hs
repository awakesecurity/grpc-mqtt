module Test.Network.GRPC.MQTT.Option (tests) where

---------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property, tripping)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

---------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Option.CLevel qualified
import Test.Network.GRPC.MQTT.Option.Gen qualified as Gen

---------------------------------------------------------------------------------

import Proto3.Suite.Class (encodeMessage, decodeMessage)

import Proto3.Wire.Decode (ParseError)
import Proto3.Wire.Encode qualified as Encode
import Proto3.Wire.Decode qualified as Decode

import Relude

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Option (ProtoOptions)

----------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Option.CLevel"
    [ Test.Network.GRPC.MQTT.Option.CLevel.tests
    , testProperty "Wire.ProtoOptions" tripWireFormatProtoOptions
    ]

tripWireFormatProtoOptions :: Property
tripWireFormatProtoOptions = property do
  clevel <- forAll Gen.protoOptions
  tripping clevel to from
  where
    to :: ProtoOptions -> LByteString
    to x = Encode.toLazyByteString (encodeMessage 0 x)

    from :: LByteString -> Either ParseError ProtoOptions
    from x = Decode.parse (decodeMessage 0) (toStrict x)
