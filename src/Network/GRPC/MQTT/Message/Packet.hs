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
    PacketSizeError (PacketSizeError),
    isValidPacketSize,
    minPacketSize,
    maxPacketSize,
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

import Control.Concurrent.TMap (TMap)
import Control.Concurrent.TMap qualified as TMap

import Control.Concurrent.STM.TQueue (TQueue, readTQueue)

import Control.Monad.Except (MonadError, liftEither)

import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as ByteString (Builder)
import Data.ByteString.Builder qualified as ByteString.Builder
import Data.Data (Data)

import Proto3.Wire.Decode (ParseError, Parser, RawMessage)
import Proto3.Wire.Decode qualified as Decode
import Proto3.Wire.Encode (MessageBuilder)
import Proto3.Wire.Encode qualified as Encode

import Relude

import Text.Printf qualified as Text

import UnliftIO (MonadUnliftIO, throwIO)
import UnliftIO.Async (concurrently_, replicateConcurrently_)
import UnliftIO.Concurrent (threadDelay)

-- Packet ----------------------------------------------------------------------

-- | 'Packet' is a MQTT packet.
--
-- @since 0.1.0.0
data Packet msg = Packet
  { -- | 'payload' is the packets payload. For a @'Packet' 'ByteString'@, this
    -- is typically a serialized protobuf message.
    payload :: msg
  , -- | 'position' is an index referring to a packets location within a stream
    -- of packets. A packets 'position' should always be strictly less than the
    -- value for 'npackets'.
    position :: {-# UNPACK #-} !Word32
  , -- | 'npackets' is the number of packets expected in this packets stream.
    -- The last or terminal packet within a stream of packets should always
    -- have a 'position' equal to @'npackets' - 1@.
    npackets :: {-# UNPACK #-} !Word32
  }
  deriving stock (Data, Eq, Generic, Ord, Show)

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
    <> Encode.fixed32 2 i
    <> Encode.fixed32 3 n
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
    <*> Decode.at (Decode.one Decode.fixed32 0) 2
    <*> Decode.at (Decode.one Decode.fixed32 1) 3
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
      bytes <- atomically (mergePacketSet packets)
      pure (toStrict bytes)

-- Packet - Packet Senders -----------------------------------------------------

newtype PacketSizeError = PacketSizeError
  {getPacketSizeError :: Integer}
  deriving stock (Data, Eq, Generic, Ord, Show)

-- | @since 1.0.0
instance Exception PacketSizeError where
  displayException exn =
    Text.printf
      "%s: maximum packet payload size must be between %d and %d bytes."
      (show exn :: String)
      minPacketSize
      maxPacketSize
  {-# INLINE displayException #-}

-- | The predicate 'isValidPacketSize' tests if the 'Word32' can be used as the
-- maximum packet payload size in 'makePacketSender'. This is any 'Word32' value
-- that is:
--
-- * Greater than or equal to 'minPacketSize'.
--
-- * Strictly less than 'maxPacketSize'.
--
-- @since 1.0.0
isValidPacketSize :: Word32 -> Bool
isValidPacketSize x = minPacketSize <= x && x < maxPacketSize

-- | The minimum packet payload size, 16 bytes.
--
-- @since 1.0.0
minPacketSize :: Word32
minPacketSize = 16

-- | The maximum packet payload size, @256mB - 128kB@.
--
-- @since 1.0.0
maxPacketSize :: Word32
maxPacketSize = 256 * 2 ^ (20 :: Int) - 128 * 2 ^ (10 :: Int)

-- | Construct a packetized message sender given the maximum size for each
-- packet payload (in bytes), the wire serialization options, and a MQTT publish
-- function.
--
-- @since 0.1.0.0
makePacketSender ::
  forall m.
  MonadUnliftIO m =>
  -- | The maximum packet payload size. This must be a 'Word32' value greater
  -- than or equal to 'minPacketSize' and less than 'maxPacketSize'. Otherwise,
  -- a 'PacketSizeError' exception will be thrown.
  Word32 ->
  -- | Optional rate limit for publishing as bytes per second.
  Maybe Natural ->
  (ByteString -> m ()) ->
  ByteString ->
  m ()
makePacketSender packetSizeLimit mRateLimit publish message = do
  unless (isValidPacketSize packetSizeLimit) do
    throwIO (PacketSizeError $ toInteger packetSizeLimit)

  if fromIntegral (ByteString.length message) <= maxPayloadSize
    then do
      -- Perform a single publish on the current thread in case that the
      -- @message@ length is less than the maximum payload size.
      let packet = Packet message 0 1
      publish (wireWrapPacket' packet)
    else do
      jobIds <- newEmptyTMVarIO
      concurrently_ (produceJobs jobIds) (publishPackets jobIds)
  where
    produceJobs :: TMVar (Maybe Word32) -> m ()
    produceJobs jobIds = do
      packetSendPeriod <-
        case mRateLimit of
          Nothing -> pure 0
          Just rateLimit -> do
            -- Throughput is rate limited on a 1 second interval and we don't subdivide packets to comply
            -- with the rate limit, so the payload size must be less than or equal to the rate limit.
            unless (fromIntegral @Word32 @Integer maxPayloadSize <= fromIntegral @Natural @Integer rateLimit) $
              throwIO (PacketSizeError $ toInteger packetSizeLimit)

            -- Convert `maxPayloadSize` and `rateLimit` to Integer first to avoid overflow. Also,
            -- the above condition that `maxPayloadSize` <= `rateLimit` ensures that the period is
            -- between 0 and 1,000,000 microseconds, so the final conversion Integer -> Int is always safe.
            pure $ fromIntegral @Integer @Int $ fromIntegral maxPayloadSize * 1_000_000 `div` fromIntegral rateLimit

      forM_ [0 .. njobs - 1] $ \jobid -> do
        atomically $ putTMVar jobIds (Just jobid)
        threadDelay packetSendPeriod
      atomically $ putTMVar jobIds Nothing

    publishPackets :: TMVar (Maybe Word32) -> m ()
    publishPackets jobIds = do
      caps <- liftIO getNumCapabilities
      replicateConcurrently_ caps $ fix \next ->
        atomically (takeTMVar jobIds) >>= \case
          Nothing -> atomically $ putTMVar jobIds Nothing
          Just jobid -> do
            let packet = makePacket jobid
            publish (wireWrapPacket' packet)
            next

    maxPayloadSize :: Word32
    maxPayloadSize = max (packetSizeLimit - minPacketSize) 1

    njobs :: Word32
    njobs = quotInf (fromIntegral $ ByteString.length message) maxPayloadSize

    -- Takes the i-th @size@ length chunk of the 'ByteString' @bytes@.
    sliceBytes :: Word32 -> ByteString
    sliceBytes i = takePayload maxPayloadSize (dropPayload (i * maxPayloadSize) message)

    makePacket :: Word32 -> Packet ByteString
    makePacket jobid = Packet (sliceBytes jobid) jobid njobs

quotInf :: Integral a => a -> a -> a
quotInf x y = quot (x + (y - 1)) y

takePayload :: Word32 -> ByteString -> ByteString
takePayload n = ByteString.take (fromIntegral n)

dropPayload :: Word32 -> ByteString -> ByteString
dropPayload n = ByteString.drop (fromIntegral n)

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
newtype PacketSet a = PacketSet
  {getPacketSet :: TMap Word32 a}

-- | Constructs an empty 'PacketSet' in 'IO'.
--
-- @since 0.1.0.0
emptyPacketSetIO :: IO (PacketSet a)
emptyPacketSetIO = fmap PacketSet TMap.emptyIO

-- | Merge the payloads of each packet in a 'PacketSet' back into the original
-- unpacketized 'ByteString'.
--
-- @since 0.1.0.0
mergePacketSet :: PacketSet ByteString -> STM LByteString
mergePacketSet (PacketSet pxs) = do
  parts <- TMap.elems pxs
  let builder :: ByteString.Builder
      builder = foldMap' ByteString.Builder.byteString parts
   in pure (ByteString.Builder.toLazyByteString builder)

-- | Inserts a 'Packet' into a 'PacketSet'. If the packet's 'metadata' has the
-- same 'position' as a previously inserted packet, then no change to the
-- 'PacketSet' is made.
--
-- @since 0.1.0.0
insertPacketSet :: Packet a -> PacketSet a -> STM ()
insertPacketSet px (PacketSet pxs) = do
  let key = position px
  let val = payload px
  exists <- TMap.member key pxs
  unless exists (TMap.insert key val pxs)

-- | Obtain the number of packets in a 'PacketSet'.
--
-- @since 0.1.0.0
lengthPacketSet :: PacketSet a -> STM Int
lengthPacketSet (PacketSet pxs) = TMap.length pxs

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
  , packets :: {-# UNPACK #-} !(PacketSet ByteString)
  , npacket :: {-# UNPACK #-} !(TMVar Word32)
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
  liftIO $ atomically do
    when (isLastPacket packet) do
      putTMVar var (position packet)
    insertPacketSet packet pxs

isMissingPackets :: PacketReader Bool
isMissingPackets = do
  var <- asks npacket
  pxs <- asks packets
  liftIO $ atomically do
    count <- tryReadTMVar var
    case count of
      Nothing -> pure True
      Just ct -> do
        len <- lengthPacketSet pxs
        pure (fromIntegral len - 1 < ct)