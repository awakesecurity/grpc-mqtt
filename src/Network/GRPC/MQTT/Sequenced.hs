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
    mkStreamPublish,
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
import Network.GRPC.MQTT.Message.Stream qualified as Stream

import Network.GRPC.MQTT.Option.Batched (Batched (Batched))

import Network.GRPC.MQTT.Serial (WireEncodeOptions)
import Network.GRPC.MQTT.Serial qualified as Serial

--------------------------------------------------------------------------------

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
  WireEncodeOptions ->
  (forall t. Message t => t -> IO ()) ->
  io (PublishToStream r)
mkStreamPublish msgLimit options publish = do
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
              publish $ Stream.wireWrapStreamChunk $ Just $ accChunks
            atomicWriteIORef chunksRef (Vector.singleton (toStrict chunk), sz)
          else do
            atomicWriteIORef chunksRef (Vector.snoc accChunks (toStrict chunk), accSize + sz)

  let unaccumulatedSend :: r -> IO ()
      unaccumulatedSend message = do
        let chunk :: Maybe (Vector ByteString)
            chunk = Just (Vector.singleton (toBS message))
         in publish (Stream.wireWrapStreamChunk chunk)

  let streamingDone :: IO ()
      streamingDone = do
        (accChunks, _) <- readIORef chunksRef
        unless (Vector.null accChunks) $
          publish $ Stream.wireWrapStreamChunk $ Just $ accChunks
        -- Send end of stream indicator
        publish $ Stream.wireWrapStreamChunk Nothing
        atomicWriteIORef chunksRef (Vector.empty, 0)

  return $
    PublishToStream
      { publishToStream =
          if Serial.encodeBatched options == Batched
            then accumulatedSend
            else unaccumulatedSend
      , publishToStreamCompleted = streamingDone
      }
