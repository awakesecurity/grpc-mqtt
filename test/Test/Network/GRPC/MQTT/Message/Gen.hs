{-# LANGUAGE NumericUnderscores #-}

-- | Generators for 'Request' messages.
module Test.Network.GRPC.MQTT.Message.Gen
  ( -- * Request Generators
    request,
    requestMessage,
    requestTimeout,

    -- * Packet Generators
    packet,
    shufflePackets,
    packetSplitLength,
    packetBytes,

    -- * Stream Chunk Generators
    streamChunk,
    streamChunkLength,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (MonadGen, Range)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

--------------------------------------------------------------------------------

import Data.ByteString qualified as ByteString
import Data.Vector (Vector)
import Data.Vector qualified as Vector

--------------------------------------------------------------------------------

import Test.Network.GRPC.HighLevel.Extra.Gen qualified as Gen
import Test.Network.GRPC.MQTT.Option.Gen qualified as Gen

import Relude

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Packet (Packet)
import Network.GRPC.MQTT.Message.Packet qualified as Packet
import Network.GRPC.MQTT.Message.Request (Request)
import Network.GRPC.MQTT.Message.Request qualified as Request

--------------------------------------------------------------------------------

-- Request Generators ----------------------------------------------------------

-- | Generates an MQTT 'Request' wrapper with a random 'ByteString' as the
-- request body.
request :: MonadGen m => m (Request ByteString)
request = do
  Request.Request
    <$> packetBytes
    <*> Gen.protoOptions
    <*> requestTimeout
    <*> Gen.metadataMap

-- | Generates possibly empty 'ByteString' with a length bounded by the size
-- parameter.
--
-- Used to emulate a serialized protobuf message embedded in a 'Request'.
requestMessage :: MonadGen m => m ByteString
requestMessage = do
  Gen.sized \size -> do
    upper <- Gen.int (Range.constant 0 (fromIntegral size))
    let range :: Range Int
        range = Range.constant 0 upper
     in Gen.bytes range

-- | Generates a request timeout in seconds, bounded [0, maxBound @Int].
requestTimeout :: MonadGen m => m Int
requestTimeout =
  let range :: Range Int
      range = Range.constant 0 maxBound
   in Gen.int range

-- Packet Generators -----------------------------------------------------------

-- | Generates a 'Packet' message.
packet :: MonadGen m => m (Packet ByteString)
packet =
  Gen.sized \size ->
    Packet.Packet
      <$> Gen.bytes (Range.constant 0 (fromIntegral size))
      <*> Gen.word32 Range.constantBounded
      <*> Gen.word32 Range.constantBounded

-- | Generates a new packets vector that is a random permutation of the vector
-- provided.
shufflePackets ::
  MonadGen m =>
  Vector (Packet ByteString) ->
  m (Vector (Packet ByteString))
shufflePackets = fmap Vector.fromList . Gen.shuffle . Vector.toList

-- | Randomly generates a maximum payload size to use when packetizing a
-- 'ByteString', bounded by the size of the 'ByteString' provided.
packetSplitLength :: MonadGen m => ByteString -> m Word32
packetSplitLength bxs =
  let upper = fromIntegral (ByteString.length bxs) 
      lower = Packet.minPacketSize
   in Gen.word32 (Range.linear lower upper)

-- | Randomly generates a 'ByteString' suitable for packetization.
packetBytes :: MonadGen m => m ByteString
packetBytes = 
  let lower :: Int 
      lower = fromIntegral Packet.minPacketSize
   in Gen.bytes (Range.linear lower 1_000)

-- Stream Chunk Generators -----------------------------------------------------

streamChunk :: MonadGen m => m (Maybe (Vector ByteString))
streamChunk = Gen.maybe do
  chunks <- Gen.list (Range.linear 1 50) do 
    let lower = fromIntegral Packet.minPacketSize
    Gen.bytes (Range.linear lower 256)
  pure (Vector.fromList chunks)

streamChunkLength :: MonadGen m => Maybe (Vector ByteString) -> m Word32
streamChunkLength Nothing = Gen.word32 (Range.constant Packet.minPacketSize 1_000)
streamChunkLength (Just xs) = do 
  let limit :: Word32 
      limit = foldr ((+) . fromIntegral . ByteString.length) 0 xs
   in Gen.word32 (Range.constant Packet.minPacketSize $ max Packet.minPacketSize limit)