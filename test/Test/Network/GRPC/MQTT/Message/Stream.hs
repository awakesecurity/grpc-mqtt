{-# LANGUAGE ImportQualifiedPost #-}

module Test.Network.GRPC.MQTT.Message.Stream
  ( -- * Test Tree
    tests,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (Property, PropertyT, forAll, property, (===))
import Hedgehog qualified

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Message.Gen qualified as Message.Gen
import qualified Test.Network.GRPC.MQTT.Option.Gen as Option.Gen

import Test.Suite.Wire qualified as Test.Wire

--------------------------------------------------------------------------------

import Control.Concurrent.Async (concurrently)
import Control.Concurrent.STM.TChan (newTChanIO, writeTChan)

import Data.Vector (Vector)
import Data.Vector qualified as Vector

import Relude hiding (reader)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message (RemoteError)
import Network.GRPC.MQTT.Message.Stream qualified as Stream
import Network.GRPC.MQTT.Message.Stream (makeStreamBatchSender, makeStreamReader)

import Network.GRPC.MQTT.Serial (WireDecodeOptions, WireEncodeOptions)
import qualified Network.GRPC.MQTT.Serial as Serial

--------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Message.Stream"
    [ testTreeStreamWire
    , testTreeStreamHandle
    ]

-- Stream.Wire -----------------------------------------------------------------

testTreeStreamWire :: TestTree
testTreeStreamWire =
  testGroup
    "Stream.Wire"
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

testTreeStreamHandle :: TestTree
testTreeStreamHandle =
  testGroup
    "Stream.Handle"
    [ testProperty "Stream.Handle.ClientToRemote" propHandleClientToRemote
    , testProperty "Stream.Handle.RemoteToClient" propHandleRemoteToClient
    ]

propHandleClientToRemote :: Property
propHandleClientToRemote = property do
  options <- forAll Option.Gen.protoOptions
  mockHandleStream
    (Serial.makeClientEncodeOptions options)
    (Serial.makeClientDecodeOptions options)

propHandleRemoteToClient :: Property
propHandleRemoteToClient = property do
  options <- forAll Option.Gen.protoOptions
  mockHandleStream
    (Serial.makeRemoteEncodeOptions options)
    (Serial.makeRemoteDecodeOptions options)

--------------------------------------------------------------------------------

-- TODO: test for 0 batching limit flushes, 

mockHandleStream :: WireEncodeOptions -> WireDecodeOptions -> PropertyT IO ()
mockHandleStream encodeOptions decodeOptions = do
  chunks <- forAll Message.Gen.streamChunk
  limit <- forAll (Message.Gen.streamChunkLength chunks)
  channel <- Hedgehog.evalIO newTChanIO

  (sender, done) <- makeStreamBatchSender @_ @IO limit encodeOptions \x -> do
    atomically (writeTChan channel (fromStrict x))

  reader <- makeStreamReader channel decodeOptions

  ((), result) <- Hedgehog.evalIO do
    concurrently
      (runSendStream sender done chunks)
      (runExceptT (runReadStream reader))

  Right chunks === result
  where
    runSendStream :: (ByteString -> IO ()) -> IO () -> Maybe (Vector ByteString) -> IO ()
    runSendStream send done = \case
      Nothing -> done
      Just cs -> do
        traverse_ send cs
        done

    runReadStream ::
      ExceptT RemoteError IO (Maybe ByteString) ->
      ExceptT RemoteError IO (Maybe (Vector ByteString))
    runReadStream read = do
      buffer <- newIORef Vector.empty

      fix \loop ->
        read >>= \case
          Nothing -> pure ()
          Just cx -> modifyIORef' buffer (`Vector.snoc` cx) >> loop

      chunks <- readIORef buffer
      if null chunks
        then pure Nothing
        else pure (Just chunks)