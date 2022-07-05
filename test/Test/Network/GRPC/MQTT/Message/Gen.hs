-- | Generators for 'Request' messages.
module Test.Network.GRPC.MQTT.Message.Gen
  ( -- * Request Generators
    request,
    requestMessage,
    requestTimeout,

    -- * Packet Generators
    packet,
    packetInfo,
    packetVector,
    shufflePackets,
    packetSplitLength,
    packetBytes,
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

import Network.GRPC.MQTT.Message.Packet (Packet, PacketInfo)
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
    <$> requestMessage
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
      <*> packetInfo

-- | Generates a 'Packet' information record.
packetInfo :: MonadGen m => m PacketInfo
packetInfo =
  Packet.PacketInfo
    <$> Gen.int Range.constantBounded
    <*> Gen.int Range.constantBounded

-- | Produces a vector of packets by packetizing a random 'ByteString'.
packetVector :: MonadGen m => m (Vector (Packet ByteString))
packetVector = do
  message <- packetBytes
  maxsize <- packetSplitLength message
  pure (Packet.splitPackets maxsize message)

-- | Generates a new packets vector that is a random permutation of the vector
-- provided.
shufflePackets ::
  MonadGen m =>
  Vector (Packet ByteString) ->
  m (Vector (Packet ByteString))
shufflePackets = fmap Vector.fromList . Gen.shuffle . Vector.toList

-- | Randomly generates a maximum payload size to use when packetizing a
-- 'ByteString', bounded by the size of the 'ByteString' provided.
packetSplitLength :: MonadGen m => ByteString -> m Int
packetSplitLength bytes =
  let range :: Range Int
      range = Range.constant 0 (ByteString.length bytes)
   in Gen.int range

-- | Randomly generates a 'ByteString' suitable for packetization.
packetBytes :: MonadGen m => m ByteString
packetBytes =
  Gen.sized \size -> do
    -- @lim@ the maximum length of a packet's payload in bytes.
    -- @num@ the maximum number of packets.
    lim <- Gen.int (Range.constant 0 (fromIntegral size))
    num <- Gen.int (Range.constant 0 (fromIntegral size))

    let range :: Range Int
        range = Range.constant 0 (lim * num)
     in Gen.bytes range
