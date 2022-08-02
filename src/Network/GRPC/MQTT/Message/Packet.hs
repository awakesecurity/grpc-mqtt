{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TemplateHaskell #-}

-- | This module exports definitions for the 'Packet' message type.
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Message.Packet
  ( -- * Packet
    Packet (Packet, payload, metadata),

    -- ** Splitting
    splitPackets,

    -- ** Wire Encoding
    wireWrapPacket,
    wireWrapPacket',
    wireBuildPacket,

    -- ** Wire Decoding
    wireUnwrapPacket,
    wireParsePacket,

    -- * Packet Readers
    makePacketReader,

    -- * Packet Senders
    makePacketSender,

    -- * PacketInfo
    PacketInfo (PacketInfo, position, npackets),

    -- ** Query
    isLastPacketInfo,

    -- * PacketSet
    PacketSet (PacketSet, getPacketSet),
    emptyPacketSetIO,
    mergePacketSet,
    insertPacketSet,
    lengthPacketSet,
  )
where

---------------------------------------------------------------------------------

import Control.Concurrent.STM.TChan (TChan, readTChan)

import Control.Monad.Except (MonadError, liftEither)

import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as ByteString (Builder)
import Data.ByteString.Builder qualified as ByteString.Builder
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Data.Vector.Mutable qualified as MVector

import Proto3.Suite (FieldNumber, decodeMessageField, encodeMessageField)

import Proto3.Wire.Decode (Parser, RawMessage)
import Proto3.Wire.Decode qualified as Decode
import Proto3.Wire.Encode (MessageBuilder)
import Proto3.Wire.Encode qualified as Encode

import Relude

import UnliftIO (MonadUnliftIO)

---------------------------------------------------------------------------------

import Control.Concurrent.TMap (TMap)
import Control.Concurrent.TMap qualified as TMap

import Network.GRPC.MQTT.Message.Packet.Core
  ( Packet (Packet, metadata, payload),
    PacketInfo (PacketInfo, npackets, position),
  )
import Network.GRPC.MQTT.Message.TH (reifyFieldNumber, reifyRecordField)

import Network.GRPC.MQTT.Message (WireDecodeError)
import Network.GRPC.MQTT.Message qualified as Message

import Network.GRPC.MQTT.Serial (WireDecodeOptions, WireEncodeOptions)

import Proto3.Wire.Decode.Extra qualified as Decode
import Proto3.Wire.Types.Extra (RecordField)

-- Packet - Splitting -----------------------------------------------------------

-- | @'splitPackets' n bytes@ splits the 'ByteString' @bytes@ into a vector of
-- packets with a 'ByteString' payload of length @n@-bytes.
--
-- A singleton packet vector with payload @bytes@ is produced in the case that
-- @n@ is negative or @bytes@ is an empty 'ByteString'.
--
-- @since 0.1.0.0
splitPackets :: Int -> ByteString -> Vector (Packet ByteString)
splitPackets size bytes
  | size <= 0 || ByteString.null bytes =
    -- In the case that the maximum packet payload length @size@ is not at least
    -- 1 byte or the provided 'ByteString' @bytes@ is empty, then yield one
    -- terminal packet.
    Vector.singleton (Packet bytes (PacketInfo 0 1))
  | otherwise = Vector.create do
    -- Allocates a vector of containing @ByteString.length bytes / size@
    -- elements rounded upwards. For example, fix the length of @bytes@ to
    -- be 5 and @size@ to be 2, then a vector of length 3 is allocated.
    let count :: Int
        count = quotCeil (ByteString.length bytes) size
     in MVector.generate count (makePacket count)
  where
    -- Takes the i-th @size@ length chunk of the 'ByteString' @bytes@.
    sliceBytes :: Int -> ByteString
    sliceBytes i = ByteString.take size (ByteString.drop (i * size) bytes)

    -- 'quot' on 'Int', rounding upwards/toward positive infinity.
    quotCeil :: Int -> Int -> Int
    quotCeil a b = (a + (b - 1)) `quot` b

    makePacket :: Int -> Int -> Packet ByteString
    makePacket count i = Packet (sliceBytes i) (PacketInfo i count)

-- Packet - Wire Format - Encoding ----------------------------------------------

-- | Encodes 'Packet' message in the wire binary format.
--
-- @since 0.1.0.0
wireWrapPacket :: WireEncodeOptions -> Packet ByteString -> LByteString
wireWrapPacket options packet = fromStrict (wireWrapPacket' options packet)

-- | Like 'wireWrapPacket', but the resulting 'ByteString' is strict.
--
-- @since 0.1.0.0
wireWrapPacket' :: WireEncodeOptions -> Packet ByteString -> ByteString
wireWrapPacket' options packet =
  wireBuildPacket packet
    & Encode.toLazyByteString
    & toStrict
    & Message.mapEncodeOptions options

-- | 'MessageBuilder' combinator capable of serializing a 'Packet' message.
--
-- @since 0.1.0.0
wireBuildPacket :: Packet ByteString -> MessageBuilder
wireBuildPacket px = wireBuildPayloadField <> wireBuildVarintsField
  where
    wireBuildPayloadField :: MessageBuilder
    wireBuildPayloadField =
      let fieldnum :: FieldNumber
          fieldnum = $(reifyFieldNumber ''Packet 'payload)
       in Encode.byteString fieldnum (payload px)

    wireBuildVarintsField :: MessageBuilder
    wireBuildVarintsField =
      let fieldnum :: FieldNumber
          fieldnum = $(reifyFieldNumber ''Packet 'metadata)
       in encodeMessageField fieldnum (metadata px)

-- Packet - Wire Format - Decoding ----------------------------------------------

-- | Parses a 'ByteString' encoding 'Packet' in the wire binary format.
--
-- @since 0.1.0.0
wireUnwrapPacket ::
  MonadError WireDecodeError m =>
  WireDecodeOptions ->
  ByteString ->
  m (Packet ByteString)
wireUnwrapPacket options bytes = do
  bytes' <- Message.mapDecodeOptions options bytes
  case Decode.parse wireParsePacket bytes' of
    Left err -> Message.throwWireError err
    Right rx -> pure rx

-- | Parses a serialized 'Packet' message.
--
-- @since 0.1.0.0
wireParsePacket :: Parser RawMessage (Packet ByteString)
wireParsePacket = Packet <$> wireParsePayloadField <*> wireParseMetadataField
  where
    wireParsePayloadField :: Parser RawMessage ByteString
    wireParsePayloadField =
      let recField :: RecordField
          recField = $(reifyRecordField ''Packet 'payload)
       in Decode.primOneField recField Decode.byteString

    wireParseMetadataField :: Parser RawMessage PacketInfo
    wireParseMetadataField =
      let recField :: RecordField
          recField = $(reifyRecordField ''Packet 'metadata)
       in Decode.msgOneField recField decodeMessageField

-- Packet - Packet Readers ----------------------------------------------------

-- | Construct an action that reads serialized packets out of a 'TChan' to
-- produce the original unpacketized 'ByteString' reconstructed from each packet
-- payload.
--
-- @since 0.1.0.0
makePacketReader ::
  (MonadIO m, MonadError WireDecodeError m) =>
  TChan LByteString ->
  WireDecodeOptions ->
  m ByteString
makePacketReader channel options = do
  liftEither =<< liftIO (runPacketReader accumulate channel)
  where
    accumulate :: PacketReader ByteString
    accumulate = do
      fix \loop -> do
        missing <- isMissingPackets
        when missing (readNextPacket options >> loop)

      packets <- asks packets
      bytes <- atomically (mergePacketSet packets)
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
  WireEncodeOptions ->
  (ByteString -> m ()) ->
  ByteString ->
  m ()
makePacketSender limit options publish message =
  let packets :: Vector (Packet ByteString)
      packets = splitPackets limit message
   in for_ packets \packet -> do
        publish (wireWrapPacket' options packet)

-- PacketInfo - Query ----------------------------------------------------------

-- | Predicate on 'PacketInfo' testing if the 'position' is the last position for
-- it's 'npackets'.
--
-- @since 0.1.0.0
isLastPacketInfo :: PacketInfo -> Bool
isLastPacketInfo info = position info == npackets info - 1

-- PacketSet -------------------------------------------------------------------

-- | 'PacketSet' is a set of packets carrying a message payload type @a@.
--
-- @since 0.1.0.0
newtype PacketSet a = PacketSet
  {getPacketSet :: TMap Int a}

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
  let key = position (metadata px)
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
  {unPacketReader :: ReaderT PacketReaderEnv (ExceptT WireDecodeError IO) a}
  deriving newtype (Functor, Applicative, Monad)
  deriving newtype (MonadIO)
  deriving newtype (MonadError WireDecodeError, MonadReader PacketReaderEnv)

-- | TODO
--
-- @since 0.1.0.0
data PacketReaderEnv = PacketReaderEnv
  { channel :: {-# UNPACK #-} !(TChan LByteString)
  , packets :: {-# UNPACK #-} !(PacketSet ByteString)
  , npacket :: {-# UNPACK #-} !(TMVar Int)
  }

runPacketReader ::
  PacketReader a ->
  TChan LByteString ->
  IO (Either WireDecodeError a)
runPacketReader m channel = do
  pxs <- liftIO emptyPacketSetIO
  var <- liftIO newEmptyTMVarIO
  unPacketReader m
    & flip runReaderT (PacketReaderEnv channel pxs var)
    & runExceptT

readNextPacket :: WireDecodeOptions -> PacketReader ()
readNextPacket options = do
  query <- asks (readTChan . channel)
  bytes <- liftIO (atomically query)
  packet <- wireUnwrapPacket options (toStrict bytes)
  pxs <- asks packets
  var <- asks npacket
  liftIO $ atomically do
    let info :: PacketInfo
        info = metadata packet
     in when (isLastPacketInfo info) do
          putTMVar var (position info)
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
        pure (len - 1 < ct)
