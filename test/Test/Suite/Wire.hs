
module Test.Suite.Wire
  ( -- * Test Combinators
    testWireClientRoundtrip,
    testWireRemoteRoundtrip,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (PropertyT, forAll, tripping)
import Hedgehog qualified as Hedgehog

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Option.Gen qualified as Option.Gen

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Serial qualified as Test.Serial

--------------------------------------------------------------------------------

import Relude hiding (reader)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Serial (WireDecodeOptions, WireEncodeOptions)
import Network.GRPC.MQTT.Serial qualified as Serial

--------------------------------------------------------------------------------

testWireClientRoundtrip ::
  (Eq a, Show a, Eq e, Show e) =>
  a ->
  (WireEncodeOptions -> a -> ByteString) ->
  (WireDecodeOptions -> ByteString -> Either e a) ->
  PropertyT IO ()
testWireClientRoundtrip x encode decode = do
  options <- forAll Option.Gen.protoOptions
  let encodeOptions = Serial.makeClientEncodeOptions options
  let decodeOptions = Serial.makeClientDecodeOptions options
  testWireRoundtrip encodeOptions decodeOptions x encode decode

testWireRemoteRoundtrip ::
  (Eq a, Show a, Eq e, Show e) =>
  a ->
  (WireEncodeOptions -> a -> ByteString) ->
  (WireDecodeOptions -> ByteString -> Either e a) ->
  PropertyT IO ()
testWireRemoteRoundtrip x encode decode = do
  options <- forAll Option.Gen.protoOptions
  let encodeOptions = Serial.makeClientEncodeOptions options
  let decodeOptions = Serial.makeClientDecodeOptions options
  testWireRoundtrip encodeOptions decodeOptions x encode decode

testWireRoundtrip ::
  (Eq a, Show a, Eq e, Show e) =>
  WireEncodeOptions ->
  WireDecodeOptions ->
  a ->
  (WireEncodeOptions -> a -> ByteString) ->
  (WireDecodeOptions -> ByteString -> Either e a) ->
  PropertyT IO ()
testWireRoundtrip encodeOptions decodeOptions x encode decode = do
  -- Annotate the test failure report with footnotes for the serialization
  -- options @encodeOptions@ and @decodeOptions@.
  Hedgehog.footnote $ "wire encoding options: " ++ show encodeOptions
  Hedgehog.footnote $ "wire decoding options: " ++ show decodeOptions

  -- Check the coherence of the serialization options provided.
  Test.Serial.diffWireOptions encodeOptions decodeOptions

  -- Test equivalence of a wire encoding-decoding roundtrip.
  tripping x (encode encodeOptions) (decode decodeOptions)
