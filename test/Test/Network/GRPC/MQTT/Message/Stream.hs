{-# LANGUAGE ImportQualifiedPost #-}

module Test.Network.GRPC.MQTT.Message.Stream
  ( -- * Test Tree
    tests,
  )
where

import Control.Concurrent.STM.TQueue (newTQueueIO)

import Data.Vector (Vector)
import Data.Vector qualified as Vector

import Hedgehog (Property, PropertyT, forAll, property, withTests, (===))
import Hedgehog qualified

import Network.GRPC.MQTT.Message (RemoteError)
import Network.GRPC.MQTT.Message.Stream qualified as Stream
import Network.GRPC.MQTT.Message.Stream (makeStreamBatchSender, makeStreamReader)
import Network.GRPC.MQTT.Serial (WireDecodeOptions, WireEncodeOptions)
import qualified Network.GRPC.MQTT.Serial as Serial

import Relude hiding (reader)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)
import Test.Network.GRPC.MQTT.Message.Gen qualified as Message.Gen
import qualified Test.Network.GRPC.MQTT.Option.Gen as Option.Gen
import Test.Suite.Wire qualified as Test.Wire
import Test.Core (mockPublish)

--------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Message.Stream"
    [ testProperty "Stream.Wire" propStreamWire
    , testProperty "Stream.Handle" $ withTests 10 propStreamHandle
    ]

propStreamWire :: Property
propStreamWire = property do
  chunk <- forAll Message.Gen.streamChunk
  Test.Wire.testWireClientRoundtrip
    chunk
    Stream.wireEncodeStreamChunk
    Stream.wireUnwrapStreamChunk

propStreamHandle :: Property
propStreamHandle = property do
  options <- forAll Option.Gen.protoOptions
  mockHandleStream
    (Serial.makeClientEncodeOptions options)
    (Serial.makeClientDecodeOptions options)

mockHandleStream :: WireEncodeOptions -> WireDecodeOptions -> PropertyT IO ()
mockHandleStream encodeOptions decodeOptions = do
  chunks <- forAll Message.Gen.streamChunk
  limit <- forAll (Message.Gen.streamChunkLength chunks)
  queue <- Hedgehog.evalIO (newTQueueIO @ByteString)

  (sender, done) <- makeStreamBatchSender @_ @IO limit encodeOptions (mockPublish queue)

  reader <- makeStreamReader queue decodeOptions

  result <- Hedgehog.evalIO do
    runSendStream sender done chunks
    runExceptT (runReadStream reader)

  Right chunks === result
  where
    runSendStream :: (ByteString -> IO ()) -> IO () -> Maybe (Vector ByteString) -> IO ()
    runSendStream send done = \case
      Nothing -> done
      Just cs -> traverse_ send cs >> done

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