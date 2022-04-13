-- | TODO:
--
-- @since 1.0.0
module Network.GRPC.MQTT.Wrap.Packet
  ( -- * Packets
    Packet (Packet),
    pktSeqNumber,
    pktIsLastPacket,
    pktPayload,
  )
where

import Proto3.Suite.Class
  ( HasDefault (def),
    Message,
    MessageField (decodeMessageField, encodeMessageField, protoType),
    Named (nameOf),
  )
import Proto3.Suite.DotProto.AST
  ( DotProtoField (DotProtoField),
    DotProtoIdentifier (Single),
    DotProtoPrimType (UInt32),
    DotProtoType (Prim),
  )
import Proto3.Wire.Decode qualified as Wire.Decode
import Proto3.Wire.Encode qualified as Wire.Encode

-- -----------------------------------------------------------------------------
--
-- Packets
--

-- | TODO:
--
-- @since 1.0.0
data Packet = Packet
  { pktIsLastPacket :: Bool
  , pktSeqNumber :: {-# UNPACK #-} !Int32
  , pktPayload :: {-# UNPACK #-} !ByteString
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (Message)

-- | @since 1.0.0
instance Named Packet where
  nameOf _ = "Packet"
  {-# INLINE CONLIKE nameOf #-}

-- | prop> def @Packet == Packet def mempty
--
-- @since 1.0.0
instance HasDefault Packet where
  def = Packet True def mempty
  {-# INLINE CONLIKE def #-}
