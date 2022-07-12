{-# LANGUAGE ImportQualifiedPost #-}

module Test.Network.GRPC.MQTT.Message.Stream
  ( -- * Test Tree
    tests,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (Property, PropertyT, forAll, property, (===))
import Hedgehog qualified as Hedgehog

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Message.Gen qualified as Message.Gen
import Test.Network.GRPC.MQTT.Option.Gen qualified as Option.Gen

import Test.Suite.Wire qualified as Test.Wire

--------------------------------------------------------------------------------

import Control.Concurrent.Async (concurrently)

import Control.Concurrent.STM.TChan (TChan, newTChanIO, writeTChan)

import Relude hiding (reader)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Stream qualified as Stream

import Network.GRPC.MQTT.Serial (WireDecodeOptions, WireEncodeOptions)
import Network.GRPC.MQTT.Serial qualified as Serial

--------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Message.Stream"
    [ testTreeStreamWire
    ]

-- Stream.Wire -----------------------------------------------------------------

testTreeStreamWire :: TestTree
testTreeStreamWire =
  testGroup
    "Packet.Wire"
    [ testProperty "Stream.Wire.Client" propPacketWireClient
    , testProperty "Stream.Wire.Remote" propPacketWireRemote
    ]

propPacketWireClient :: Property
propPacketWireClient = property do
  chunk <- forAll Message.Gen.streamChunk
  Test.Wire.testWireClientRoundtrip
    chunk
    Stream.wireEncodeStreamChunk
    Stream.wireUnwrapStreamChunk

propPacketWireRemote :: Property
propPacketWireRemote = property do
  chunk <- forAll Message.Gen.streamChunk
  Test.Wire.testWireRemoteRoundtrip
    chunk
    Stream.wireEncodeStreamChunk
    Stream.wireUnwrapStreamChunk

-- Stream.Handle ---------------------------------------------------------------

-- testTreeStreamHandle :: TestTree
-- testTreeStreamHandle =
--   testGroup
--     "Stream.Handle"
--     [ testProperty "Stream.Handle.ClientToRemote" propHandleClientToRemote
--     , testProperty "Stream.Handle.RemoteToClient" propHandleRemoteToClient
--     ]

-- propHandleClientToRemote :: Property
-- propHandleClientToRemote = property do
--   options <- forAll Option.Gen.protoOptions
--   mockHandleStream
--     (Serial.makeClientEncodeOptions options)
--     (Serial.makeClientDecodeOptions options)

-- propHandleRemoteToClient :: Property
-- propHandleRemoteToClient = property do
--   options <- forAll Option.Gen.protoOptions
--   mockHandleStream
--     (Serial.makeRemoteEncodeOptions options)
--     (Serial.makeRemoteDecodeOptions options)

-- mockHandleStream :: WireEncodeOptions -> WireDecodeOptions -> PropertyT IO ()
-- mockHandleStream encodeOptions decodeOptions = do
--   message <- forAll (Gen.)
--   channel <- Hedgehog.evalIO newTChanIO
--   maxsize <- forAll (Message.Gen.packetSplitLength message)

--   reader <- Hedgehog.evalIO do
--     Stream.makeStreamReader channel decodeOptions

--   (sender, done) <- Hedgehog.evalIO do
--     Stream.makeStreamBatchSender maxsize encodeOptions (mockPublish channel)

--   ((), result) <- Hedgehog.evalIO do
--     concurrently _ (runExceptT reader)

--   Right (Just message) === result

-- mockPublish :: TChan LByteString -> ByteString -> IO ()
-- mockPublish channel message = atomically do
--   let message' :: LByteString
--       message' = fromStrict @LByteString @ByteString message
--    in writeTChan channel message'