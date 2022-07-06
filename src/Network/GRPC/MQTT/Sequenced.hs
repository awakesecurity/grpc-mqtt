{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Sequenced
  ( PublishToStream (..),
    mkPacketizedPublish,
    mkStreamPublish,
    mkStreamRead,
  )
where

--------------------------------------------------------------------------------

import Data.ByteString.Lazy qualified as LByteString
import Data.Vector (Vector)
import Data.Vector qualified as Vector

import Network.GRPC.HighLevel.Server (toBS)

import Network.MQTT.Client (MQTTClient, QoS (QoS1), publishq)
import Network.MQTT.Topic (Topic)

import Proto3.Suite (Message, toLazyByteString)

import Relude hiding (reader)

import UnliftIO (MonadUnliftIO)
import UnliftIO.Async qualified as Async

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Packet (Packet)
import Network.GRPC.MQTT.Message.Packet qualified as Packet
import Network.GRPC.MQTT.Message.StreamChunk qualified as StreamChunk
import Network.GRPC.MQTT.Option.Batched (Batched (Batched))

-- import Network.GRPC.MQTT.Wrapping
--   ( unwrapStreamChunk,
--     wrapStreamChunk,
--   )

import Proto.Mqtt (RemoteError)

--------------------------------------------------------------------------------

mkStreamRead ::
  MonadIO io =>
  ExceptT RemoteError IO ByteString ->
  io (ExceptT RemoteError IO (Maybe ByteString))
mkStreamRead reader = do
  buffer <- newIORef (Vector.empty @ByteString)
  let readNextChunk :: ExceptT RemoteError IO (Maybe ByteString)
      readNextChunk = do
        result <- StreamChunk.wireUnwrapStreamChunk =<< reader
        case result of
          Nothing ->
            -- Read the terminal stream chunk 'Nothing': yield 'Nothing'
            -- terminating the streaming loop.
            pure Nothing
          Just chunks -> do
            -- Read a collection of stream chunks: buffer each chunk in the
            -- order they were recieved.
            atomicWriteIORef buffer chunks
            makeChunkBuffer

      makeChunkBuffer :: ExceptT RemoteError IO (Maybe ByteString)
      makeChunkBuffer = do
        chunks <- readIORef buffer
        case Vector.uncons chunks of
          Nothing ->
            -- The stream chunk buffer is empty, attempt to read the next set
            -- of stream chunk(s).
            readNextChunk
          Just (cx, cxs) -> do
            -- Pop the first stream chunk off the @buffer@ and return it.
            -- Replace the remaining chunks back into the @buffer@.
            atomicWriteIORef buffer cxs
            pure (Just cx)
   in pure readNextChunk

mkPacketizedPublish ::
  MonadUnliftIO io =>
  MQTTClient ->
  Int64 ->
  Topic ->
  LByteString ->
  io ()
mkPacketizedPublish client msgLimit topic bytes =
  let packets :: Vector (Packet ByteString)
      packets = Packet.splitPackets (fromIntegral msgLimit) (toStrict bytes)
   in Async.forConcurrently_ packets \packet -> do
        let encoded :: LByteString
            encoded = Packet.wireWrapPacket packet
         in liftIO (publishq client topic encoded False QoS1 [])

data PublishToStream a = PublishToStream
  { -- | A function to publish one data element.
    publishToStream :: a -> IO ()
  , -- | This function should be called to indicate that streaming is
    -- completed.
    publishToStreamCompleted :: IO ()
  }

mkStreamPublish ::
  forall r io.
  (Message r, MonadIO io) =>
  Int64 ->
  Batched ->
  (forall t. Message t => t -> IO ()) ->
  io (PublishToStream r)
mkStreamPublish msgLimit useBatch publish = do
  -- NOTE: Ensure the quantified @t@ or message @r@ are not 'ByteString'.
  -- Otherwise, it is possible for stream chunks to be encoded twice which would
  -- produce a WireTypeError when parsing.

  chunksRef <- newIORef ((Vector.empty, 0) :: (Vector ByteString, Int64))

  let accumulatedSend :: r -> IO ()
      accumulatedSend a = do
        (accChunks, accSize) <- readIORef chunksRef
        let chunk = toLazyByteString a
            sz = LByteString.length chunk
        if accSize + sz > msgLimit
          then do
            unless (Vector.null accChunks) $
              publish $ StreamChunk.wireWrapStreamChunk $ Just $ accChunks
            atomicWriteIORef chunksRef (Vector.singleton (toStrict chunk), sz)
          else do
            atomicWriteIORef chunksRef (Vector.snoc accChunks (toStrict chunk), accSize + sz)

  let unaccumulatedSend :: r -> IO ()
      unaccumulatedSend message = do
        let chunk :: Maybe (Vector ByteString)
            chunk = Just (Vector.singleton (toBS message))
         in publish (StreamChunk.wireWrapStreamChunk chunk)

  let streamingDone :: IO ()
      streamingDone = do
        (accChunks, _) <- readIORef chunksRef
        unless (Vector.null accChunks) $
          publish $ StreamChunk.wireWrapStreamChunk $ Just $ accChunks
        -- Send end of stream indicator
        publish $ StreamChunk.wireWrapStreamChunk Nothing
        atomicWriteIORef chunksRef (Vector.empty, 0)

  return $
    PublishToStream
      { publishToStream = if useBatch == Batched then accumulatedSend else unaccumulatedSend
      , publishToStreamCompleted = streamingDone
      }
