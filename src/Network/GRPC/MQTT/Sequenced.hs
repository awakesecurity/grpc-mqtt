{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ImplicitPrelude #-}

module Network.GRPC.MQTT.Sequenced
  ( PublishToStream (..),
    packetReader,
    mkPacketizedPublish,
    mkStreamPublish,
    mkStreamRead,
  )
where

--------------------------------------------------------------------------------

import Control.Concurrent.STM (STM, atomically)
import Control.Concurrent.STM.TChan (TChan, readTChan)
import Control.Concurrent.STM.TVar (modifyTVar', newTVarIO, readTVar)

import Control.Monad (unless)
import Control.Monad.Except (ExceptT, throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)

import Data.Foldable (foldl', toList)
import Data.IORef (IORef, newIORef, readIORef, atomicWriteIORef)
import Data.Int (Int64)

import Data.ByteString (ByteString)
import Data.ByteString.Builder qualified as ByteString (Builder)
import Data.ByteString.Builder qualified as ByteString.Builder
import Data.ByteString.Lazy qualified as Lazy (ByteString)
import Data.ByteString.Lazy qualified as Lazy.ByteString
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Vector (Vector)
import Data.Vector qualified as Vector

import Network.GRPC.HighLevel.Server (toBS)

import Network.MQTT.Client (MQTTClient, QoS (QoS1), publishq)
import Network.MQTT.Topic (Topic)

import Proto3.Suite (Message, fromByteString, toLazyByteString)
import Proto3.Wire.Decode qualified as Decode

--------------------------------------------------------------------------------

import Control.Concurrent.TMap (TMap)
import Control.Concurrent.TMap qualified as TMap

import Network.GRPC.MQTT.Types (Batched (Batched))
import Network.GRPC.MQTT.Wrapping
  ( wrapStreamChunk,
    unwrapStreamChunk,
  )

import Proto.Mqtt (Packet (..), RemoteError)

--------------------------------------------------------------------------------

-- | Reads, parses, and orders serialized 'Packet' messages from the source
-- 'TChan'. Returns the serialized message reconstructed from each packet
-- obtained from the channel.
--
-- @since 1.0.0
packetReader ::
  TChan Lazy.ByteString ->
  ExceptT Decode.ParseError IO Lazy.ByteString
packetReader channel = do
  payloads <- liftIO (atomically (orderPacketReader channel))
  case payloads of
    Left err -> throwError err
    Right xs -> pure (ByteString.Builder.toLazyByteString (builder xs))
  where
    builder :: [ByteString] -> ByteString.Builder
    builder = foldl' (\xs x -> xs <> ByteString.Builder.byteString x) mempty

-- | Reads a complete sequence of serialized 'Packet' messages from the source
-- 'TChan' given. Returns an 'STM' action of sequenced packets read from the
-- 'TChan' or a 'Decode.ParseError' raised while attempt to parse one or more
-- of the channel's 'ByteString' as a 'Packet'.
--
-- @since 1.0.0
orderPacketReader ::
  TChan Lazy.ByteString ->
  STM (Either Decode.ParseError [ByteString])
orderPacketReader channel = do
  buffer <- TMap.empty
  result <- collect buffer

  case result of
    Nothing -> do
      chunks <- TMap.toAscList buffer
      pure (Right (map snd chunks))
    Just err -> do
      pure (Left err)
  where
    collect :: TMap Int ByteString -> STM (Maybe Decode.ParseError)
    collect buffer = do
      decoded <- decodePacket
      case decoded of
        Left perr -> pure (Just perr)
        Right pkt -> do
          insertPacket pkt buffer
          if packetTerminal pkt
            then pure Nothing
            else collect buffer

    insertPacket :: Packet -> TMap Int ByteString -> STM ()
    insertPacket (Packet _ ix raw) = TMap.insert (fromIntegral ix) raw

    decodePacket :: STM (Either Decode.ParseError Packet)
    decodePacket = do
      raw <- readTChan channel
      pure (fromByteString (Lazy.ByteString.toStrict raw))

mkStreamRead ::
  forall io a.
  (MonadIO io, Message a) =>
  ExceptT RemoteError IO Lazy.ByteString ->
  io (ExceptT RemoteError IO (Maybe a))
mkStreamRead readRequest = liftIO do
  -- NOTE: The type signature should be left here to bind the message type
  -- @a@, otherwise it is easy for the @Message@ instance used by the
  -- @fromByteString@ in @unwrapStreamChunk@ to resolve to some other type,
  -- resulting in a parse error.

  reqsRef :: IORef (Maybe (Vector a)) <- newIORef (Just Vector.empty)

  let readNextChunk :: ExceptT RemoteError IO ()
      readNextChunk = do
        bytes <- readRequest
        case unwrapStreamChunk bytes of
          Left err -> do
            liftIO (atomicWriteIORef reqsRef Nothing)
            throwError err
          Right xs -> do
            liftIO (atomicWriteIORef reqsRef xs)

  let readStreamChunk :: ExceptT RemoteError IO (Maybe a)
      readStreamChunk =
        liftIO (readIORef reqsRef) >>= \case
          Nothing -> pure Nothing
          Just reqs ->
            if Vector.null reqs
              then readNextChunk >> readStreamChunk
              else liftIO do
                atomicWriteIORef reqsRef (Just $ Vector.tail reqs)
                return (Just $ Vector.head reqs)

  return readStreamChunk


mkPacketizedPublish :: (MonadIO io) => MQTTClient -> Int64 -> Topic -> io (Lazy.ByteString -> IO ())
mkPacketizedPublish client msgLimit topic = liftIO do
  seqVar <- newTVarIO 0

  let packetizedPublish :: Lazy.ByteString -> IO ()
      packetizedPublish bs = do
        let (chunk, rest) = Lazy.ByteString.splitAt msgLimit bs
        let isLastPacket = Lazy.ByteString.null rest

        rawPacket <- atomically $ do
          curSeq <- readTVar seqVar
          modifyTVar' seqVar (+ 1)
          return $ toLazyByteString $ Packet isLastPacket curSeq (Lazy.ByteString.toStrict chunk)

        publishq client topic rawPacket False QoS1 []

        unless isLastPacket $ packetizedPublish rest

  return packetizedPublish

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
mkStreamPublish msgLimit useBatch publish = liftIO do
  chunksRef <- newIORef ((Seq.empty, 0) :: (Seq ByteString, Int64))

  let seqToVector :: Seq t -> Vector t
      seqToVector = Vector.fromList . toList

  let accumulatedSend :: r -> IO ()
      accumulatedSend a = do
        (accChunks, accSize) <- readIORef chunksRef
        let chunk = toLazyByteString a
            sz = Lazy.ByteString.length chunk
        if accSize + sz > msgLimit
          then do
            unless (Seq.null accChunks) $
              publish $ wrapStreamChunk $ Just $ seqToVector accChunks
            atomicWriteIORef chunksRef (Seq.singleton (Lazy.ByteString.toStrict chunk), sz)
          else do
            atomicWriteIORef chunksRef (accChunks |> Lazy.ByteString.toStrict chunk, accSize + sz)

  let unaccumulatedSend :: r -> IO ()
      unaccumulatedSend = publish . wrapStreamChunk . Just . Vector.singleton . toBS

  let streamingDone :: IO ()
      streamingDone = do
        (accChunks, _) <- readIORef chunksRef
        unless (Seq.null accChunks) $
          publish $ wrapStreamChunk $ Just $ seqToVector accChunks
        -- Send end of stream indicator
        publish $ wrapStreamChunk Nothing
        atomicWriteIORef chunksRef (Seq.empty, 0)

  return $
    PublishToStream
      { publishToStream = if useBatch == Batched then accumulatedSend else unaccumulatedSend
      , publishToStreamCompleted = streamingDone
      }
