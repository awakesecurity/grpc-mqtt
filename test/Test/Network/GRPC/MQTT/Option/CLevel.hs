module Test.Network.GRPC.MQTT.Option.CLevel (tests) where

---------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property, tripping)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

---------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Option.Gen qualified as Gen

---------------------------------------------------------------------------------

import Proto3.Suite.Class (encodePrimitive, decodePrimitive)

import Proto3.Wire.Decode (Parser, ParseError, RawMessage)
import Proto3.Wire.Encode qualified as Encode
import Proto3.Wire.Decode qualified as Decode

import Relude

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Proto (castDatum)
import Network.GRPC.MQTT.Option.CLevel (CLevel)
import Network.GRPC.MQTT.Option.CLevel qualified as CLevel

----------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Option.CLevel"
    [ testProperty "Datum.CLevel" tripDatumCLevel
    , testProperty "Wire.CLevel" tripWireFormatCLevel
    ]

tripDatumCLevel :: Property
tripDatumCLevel = property do
  clevel <- forAll Gen.clevel
  tripping clevel CLevel.toProtoValue castDatum

tripWireFormatCLevel :: Property
tripWireFormatCLevel = property do
  clevel <- forAll Gen.clevel
  tripping clevel to from
  where
    to :: CLevel -> LByteString
    to x = Encode.toLazyByteString (encodePrimitive 0 x)

    from :: LByteString -> Either ParseError CLevel
    from x =
      let primParse :: Parser RawMessage CLevel
          primParse = Decode.at (Decode.one decodePrimitive (CLevel.CLevel 0)) 0
       in Decode.parse primParse (toStrict x)
