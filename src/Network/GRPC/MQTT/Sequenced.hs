{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Sequenced where

import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LBS
import Data.Sequence ((|>))
import Data.Sequence qualified as Seq
import Data.SortedList qualified as SL
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Network.GRPC.HighLevel.Server (toBS)
import Network.GRPC.MQTT.Types (Batched (Batched))
import Network.GRPC.MQTT.Wrapping (fromLazyByteString, unwrapStreamChunk, wrapStreamChunk)
import Network.MQTT.Client (MQTTClient, QoS (QoS1), publishq)
import Network.MQTT.Topic (Topic)
import Proto.Mqtt (Packet (..), RemoteError)
import Proto3.Suite (Message, toLazyByteString)
import UnliftIO.STM (TChan, readTChan)

--------------------------------------------------------------------------------

data SequenceIdx
  = Unsequenced
  | SequencedIdx Natural
  deriving stock (Eq, Ord)

-- | A class representing types that have some form of sequence id
class Sequenced a where
  type Payload a

  seqNum :: a -> SequenceIdx

  seqPayload :: a -> Payload a

-- | A newtype wrapper to use 'seqNum` for its 'Ord' and 'Eq' instances
newtype SequencedWrap a = SequencedWrap a
  deriving stock (Show)
  deriving newtype (Sequenced)

instance Sequenced a => Eq (SequencedWrap a) where
  (==) = (==) `on` seqNum

instance Sequenced a => Ord (SequencedWrap a) where
  (<=) = (<=) `on` seqNum

-- 'Either' can be sequenced where 'Left' represents an error and will
-- always be given first in the sequence
instance (Sequenced a) => Sequenced (Either e a) where
  type Payload (Either e a) = Either e (Payload a)
  seqNum (Left _) = Unsequenced
  seqNum (Right a) = seqNum a
  seqPayload = fmap seqPayload

instance Sequenced Packet where
  type Payload Packet = ByteString
  seqNum Packet{..} =
    if packetSequenceNum < 0
      then Unsequenced
      else SequencedIdx (fromIntegral packetSequenceNum)

  seqPayload = packetPayload

mkPacketizedRead :: forall io. (MonadIO io) => TChan LByteString -> io (ExceptT RemoteError io LByteString)
mkPacketizedRead chan = do
  let read = fromLazyByteString @Packet <$> readTChan chan
  readSeq <- mkSequencedRead read

  let readMessage :: Builder.Builder -> ExceptT RemoteError io LByteString
      readMessage acc = do
        (Packet isLastPacket _ chunk) <- ExceptT readSeq
        let builder = acc <> Builder.byteString chunk
        if isLastPacket
          then pure $ Builder.toLazyByteString builder
          else readMessage builder

  return $ readMessage mempty

-- | Given an 'STM' action that gets a 'Sequenced' object, creates a new wrapped action that will
-- read the objects in order even if they are received out of order
-- NB: Objects with negative sequence numbers are always returned immediately
mkSequencedRead :: forall io a. (MonadIO io, Sequenced a) => STM a -> io (io a)
mkSequencedRead read = do
  seqVar <- newTVarIO 0
  bufferVar <- newTVarIO $ SL.toSortedList @(SequencedWrap a) []

  let orderedRead :: STM a
      orderedRead = do
        curSeq <- readTVar seqVar
        buffer <- readTVar bufferVar

        sa <- case SL.uncons buffer of
          Just (sa, rest)
            | SequencedIdx idx <- seqNum sa
              , curSeq == idx ->
              writeTVar bufferVar rest $> sa
          _ -> coerce read

        case seqNum sa of
          Unsequenced -> return $ coerce sa
          SequencedIdx idx ->
            case idx `compare` curSeq of
              -- If sequence number is less than current, it must be a duplicate, so we discard it and read again
              LT -> orderedRead
              EQ -> modifyTVar' seqVar (+ 1) $> coerce sa
              GT -> modifyTVar' bufferVar (SL.insert sa) >> orderedRead

  return $ atomically orderedRead

mkStreamRead :: forall r io. (Message r, MonadIO io) => ExceptT RemoteError IO LByteString -> io (ExceptT RemoteError IO (Maybe r))
mkStreamRead readRequest = do
  reqsRef :: IORef (Maybe (Vector r)) <- newIORef (Just Vector.empty)

  let readNextChunk :: ExceptT RemoteError IO ()
      readNextChunk = do
        res <- readRequest
        cs <- hoistEither $ unwrapStreamChunk res
        writeIORef reqsRef cs

  let readStreamChunk :: ExceptT RemoteError IO (Maybe r)
      readStreamChunk =
        readIORef reqsRef >>= \case
          Nothing -> pure Nothing
          Just reqs ->
            if Vector.null reqs
              then readNextChunk >> readStreamChunk
              else writeIORef reqsRef (Just $ Vector.tail reqs) >> return (Just $ Vector.head reqs)

  return readStreamChunk

mkPacketizedPublish :: (MonadIO io) => MQTTClient -> Int64 -> Topic -> io (LByteString -> IO ())
mkPacketizedPublish client msgLimit topic = do
  seqVar <- newTVarIO 0

  let packetizedPublish :: LByteString -> IO ()
      packetizedPublish bs = do
        let (chunk, rest) = LBS.splitAt msgLimit bs
        let isLastPacket = LBS.null rest

        rawPacket <- atomically $ do
          curSeq <- readTVar seqVar
          modifyTVar' seqVar (+ 1)
          return $ toLazyByteString $ Packet isLastPacket curSeq (toStrict chunk)

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
mkStreamPublish msgLimit useBatch publish = do
  chunksRef <- newIORef ((Seq.empty, 0) :: (Seq ByteString, Int64))

  let seqToVector :: Seq t -> Vector t
      seqToVector = fromList . toList

  let accumulatedSend :: r -> IO ()
      accumulatedSend a = do
        (accChunks, accSize) <- readIORef chunksRef
        let chunk = toLazyByteString a
            sz = LBS.length chunk
        if accSize + sz > msgLimit
          then do
            unless (Seq.null accChunks) $
              publish $ wrapStreamChunk $ Just $ seqToVector accChunks
            writeIORef chunksRef (Seq.singleton (toStrict chunk), sz)
          else writeIORef chunksRef (accChunks |> toStrict chunk, accSize + sz)

  let unaccumulatedSend :: r -> IO ()
      unaccumulatedSend = publish . wrapStreamChunk . Just . Vector.singleton . toBS

  let streamingDone :: IO ()
      streamingDone = do
        (accChunks, _) <- readIORef chunksRef
        unless (Seq.null accChunks) $
          publish $ wrapStreamChunk $ Just $ seqToVector accChunks
        -- Send end of stream indicator
        publish $ wrapStreamChunk Nothing
        writeIORef chunksRef (Seq.empty, 0)

  return $
    PublishToStream
      { publishToStream = if useBatch == Batched then accumulatedSend else unaccumulatedSend
      , publishToStreamCompleted = streamingDone
      }
