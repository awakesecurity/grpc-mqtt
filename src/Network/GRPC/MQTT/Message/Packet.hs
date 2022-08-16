{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE TemplateHaskell #-}

-- | This module exports definitions for the 'Packet' message type.
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Message.Packet
  ( -- * Packet
    Packet (Packet, payload, position, npackets),

    -- * Wire Encoding
    wireWrapPacket,
    wireWrapPacket',
    wireBuildPacket,

    -- * Wire Decoding
    wireUnwrapPacket,
    wireParsePacket,

    -- * Packet Readers
    makePacketReader,

    -- * Packet Senders
    makePacketSender,

    -- * Query
    isLastPacket,

    -- * PacketSet
    PacketSet (PacketSet, getPacketSet),
    emptyPacketSetIO,
    mergePacketSet,
    insertPacketSet,
    lengthPacketSet,
  )
where

--------------------------------------------------------------------------------

import Control.Concurrent (getNumCapabilities)

import Control.Concurrent.STM.TQueue (TQueue, readTQueue)

import Control.Monad.Except (MonadError, liftEither)

import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as ByteString (Builder)
import Data.ByteString.Builder qualified as ByteString.Builder
import Data.Data (Data)
import Data.IntMap.Strict qualified as IntMap

import Proto3.Wire.Decode (ParseError, Parser, RawMessage)
import Proto3.Wire.Decode qualified as Decode
import Proto3.Wire.Encode (MessageBuilder)
import Proto3.Wire.Encode qualified as Encode

import Relude

import UnliftIO (MonadUnliftIO)
import UnliftIO.Async (replicateConcurrently_)

-- Packet ----------------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
data Packet msg = Packet
  { payload :: msg
  , position :: {-# UNPACK #-} !Int
  , npackets :: {-# UNPACK #-} !Int
  }
  deriving stock (Eq, Ord, Show)
  deriving stock (Data, Generic, Typeable)

-- Packet - Wire Format - Encoding ----------------------------------------------

-- | Encodes 'Packet' message in the wire binary format.
--
-- @since 0.1.0.0
wireWrapPacket :: Packet ByteString -> LByteString
wireWrapPacket = Encode.toLazyByteString . wireBuildPacket
{-# INLINE wireWrapPacket #-}

-- | Like 'wireWrapPacket', but the resulting 'ByteString' is strict.
--
-- @since 0.1.0.0
wireWrapPacket' :: Packet ByteString -> ByteString
wireWrapPacket' = toStrict . wireWrapPacket
{-# INLINE wireWrapPacket' #-}

-- | 'MessageBuilder' combinator capable of serializing a 'Packet' message.
--
-- @since 0.1.0.0
wireBuildPacket :: Packet ByteString -> MessageBuilder
wireBuildPacket (Packet bxs i n) =
  Encode.byteString 1 bxs
    <> Encode.sint64 2 (fromIntegral i)
    <> Encode.sint64 3 (fromIntegral n)
{-# INLINE wireBuildPacket #-}

-- Packet - Wire Format - Decoding ----------------------------------------------

-- | Parses a 'ByteString' encoding 'Packet' in the wire binary format.
--
-- @since 0.1.0.0
wireUnwrapPacket ::
  MonadError ParseError m =>
  ByteString ->
  m (Packet ByteString)
wireUnwrapPacket bxs = liftEither (Decode.parse wireParsePacket bxs)
{-# INLINE wireUnwrapPacket #-}

-- | Parses a serialized 'Packet' message.
--
-- @since 0.1.0.0
wireParsePacket :: Parser RawMessage (Packet ByteString)
wireParsePacket =
  Packet
    <$> Decode.at (Decode.one Decode.byteString ByteString.empty) 1
    <*> Decode.at (fromIntegral <$> Decode.one Decode.sint64 0) 2
    <*> Decode.at (fromIntegral <$> Decode.one Decode.sint64 1) 3
{-# INLINE wireParsePacket #-}

-- Packet - Packet Readers ----------------------------------------------------

-- | Construct an action that reads serialized packets out of a 'TChan' to
-- produce the original unpacketized 'ByteString' reconstructed from each packet
-- payload.
--
-- @since 0.1.0.0
makePacketReader ::
  (MonadIO m, MonadError ParseError m) =>
  TQueue ByteString ->
  m ByteString
makePacketReader queue = do
  liftEither =<< liftIO (runPacketReader accumulate queue)
  where
    accumulate :: PacketReader ByteString
    accumulate = do
      fix \loop -> do
        missing <- isMissingPackets
        when missing (readNextPacket >> loop)

      packets <- asks packets
      bytes <- liftIO (mergePacketSet packets)
      pure (toStrict bytes)

-- Packet - Packet Senders -----------------------------------------------------

-- | Construct a packetized message sender given the maximum size for each
-- packet payload (in bytes), the wire serialization options, and a MQTT publish
-- function.
--
-- @since 0.1.0.0
makePacketSender ::
  MonadUnliftIO m =>
  Int ->
  (ByteString -> m ()) ->
  ByteString ->
  m ()
makePacketSender limit publish message
  | limit <= 0 || ByteString.length message < limit =
    -- In the case that the maximum packet payload length @size@ is not at least
    -- 1 byte or the provided 'ByteString' @bytes@ is empty, then yield one
    -- terminal packet.
    let packet :: Packet ByteString
        packet = Packet message 0 1
     in publish (wireWrapPacket' packet)
  | otherwise = do
    caps <- liftIO getNumCapabilities
    jobs <- newTVarIO 0

    replicateConcurrently_ caps $ fix \next ->
      atomically (takeJobId jobs) >>= \case
        Nothing -> pure ()
        Just jobid -> do
          let packet :: Packet ByteString
              packet = makePacket jobid
           in publish (wireWrapPacket' packet)
          next
  where
    njobs :: Int
    njobs = (ByteString.length message + (limit - 1)) `quot` limit

    takeJobId :: TVar Int -> STM (Maybe Int)
    takeJobId jobs = do
      jobid <- readTVar jobs
      if jobid < njobs
        then writeTVar jobs (1 + jobid) $> Just jobid
        else pure Nothing

    -- Takes the i-th @size@ length chunk of the 'ByteString' @bytes@.
    sliceBytes :: Int -> ByteString
    sliceBytes i = ByteString.take limit (ByteString.drop (i * limit) message)

    makePacket :: Int -> Packet ByteString
    makePacket jobid = Packet (sliceBytes jobid) jobid njobs

-- PacketInfo - Query ----------------------------------------------------------

-- | Predicate on 'PacketInfo' testing if the 'position' is the last position for
-- it's 'npackets'.
--
-- @since 0.1.0.0
isLastPacket :: Packet a -> Bool
isLastPacket (Packet _ i n) = i == n - 1

-- PacketSet -------------------------------------------------------------------

-- | 'PacketSet' is a set of packets carrying a message payload type @a@.
--
-- @since 0.1.0.0
newtype PacketSet = PacketSet
  {getPacketSet :: IORef (IntMap ByteString)}

-- | Constructs an empty 'PacketSet' in 'IO'.
--
-- @since 0.1.0.0
emptyPacketSetIO :: IO PacketSet
emptyPacketSetIO = PacketSet <$> newIORef IntMap.empty

-- | Merge the payloads of each packet in a 'PacketSet' back into the original
-- unpacketized 'ByteString'.
--
-- @since 0.1.0.0
mergePacketSet :: PacketSet -> IO LByteString
mergePacketSet (PacketSet var) = do
  kvs <- readIORef var
  let builder :: ByteString.Builder
      builder = foldMap' ByteString.Builder.byteString kvs
   in pure (ByteString.Builder.toLazyByteString builder)

-- | Inserts a 'Packet' into a 'PacketSet'. If the packet's 'metadata' has the
-- same 'position' as a previously inserted packet, then no change to the
-- 'PacketSet' is made.
--
-- @since 0.1.0.0
insertPacketSet :: Packet ByteString -> PacketSet -> IO ()
insertPacketSet px (PacketSet var) = do
  let key = position px
  let val = payload px
  kvs <- readIORef var
  unless (IntMap.member key kvs) do
    -- TODO: document!!
    -- TODO: MUST BE ATOMIC WRITE/MODIFY!!!!
    atomicWriteIORef var (IntMap.insert key val kvs)

-- | Obtain the number of packets in a 'PacketSet'.
--
-- @since 0.1.0.0
lengthPacketSet :: PacketSet -> IO Int
lengthPacketSet (PacketSet pxs) = length <$> readIORef pxs

-- ------------------------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
newtype PacketReader a = PacketReader
  {unPacketReader :: ReaderT PacketReaderEnv (ExceptT ParseError IO) a}
  deriving newtype (Functor, Applicative, Monad)
  deriving newtype (MonadIO)
  deriving newtype (MonadError ParseError, MonadReader PacketReaderEnv)

-- | TODO
--
-- @since 0.1.0.0
data PacketReaderEnv = PacketReaderEnv
  { queue :: {-# UNPACK #-} !(TQueue ByteString)
  , packets :: {-# UNPACK #-} !PacketSet
  , npacket :: {-# UNPACK #-} !(TMVar Int)
  }

runPacketReader ::
  PacketReader a ->
  TQueue ByteString ->
  IO (Either ParseError a)
runPacketReader m queue = do
  pxs <- liftIO emptyPacketSetIO
  var <- liftIO newEmptyTMVarIO
  unPacketReader m
    & flip runReaderT (PacketReaderEnv queue pxs var)
    & runExceptT

readNextPacket :: PacketReader ()
readNextPacket = do
  query <- asks (readTQueue . queue)
  bytes <- liftIO (atomically query)
  packet <- wireUnwrapPacket bytes
  pxs <- asks packets
  var <- asks npacket
  liftIO do
    when (isLastPacket packet) do
      atomically (putTMVar var (position packet))
    insertPacketSet packet pxs

isMissingPackets :: PacketReader Bool
isMissingPackets = do
  var <- asks npacket
  pxs <- asks packets
  liftIO do
    count <- atomically (tryReadTMVar var)
    case count of
      Nothing -> pure True
      Just ct -> do
        len <- lengthPacketSet pxs
        pure (len - 1 < ct)
