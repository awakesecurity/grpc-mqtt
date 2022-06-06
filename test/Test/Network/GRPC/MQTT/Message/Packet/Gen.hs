{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | Generators for 'Packet' messages.
module Test.Network.GRPC.MQTT.Message.Packet.Gen
  ( -- * Generators
    packet,
    packetInfo,
    packetVector,
    shufflePackets,
    packetSplitLength,
    packetBytes,
  )
where

---------------------------------------------------------------------------------

import Hedgehog (MonadGen, Range)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

---------------------------------------------------------------------------------

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Vector (Vector)
import Data.Vector qualified as Vector

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Packet (Packet, PacketInfo)
import Network.GRPC.MQTT.Message.Packet qualified as Packet

---------------------------------------------------------------------------------

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
