-- | TODO:
--
-- @since 1.0.0
module Network.GRPC.MQTT.Wrap.Packet
  ( -- * Packets
    Packet (Packet),
    pktSeqInfo,
    pktPayload,

    -- ** Predicates
    isPktTerminal,

    -- * Sequence Information
    SeqInfo (SeqInfo, SeqTerm),

    -- ** Predicates
    isSeqTerminal,

    -- ** Conversion
    toSeqIx,
    fromSeqIx,
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
  { pktSeqInfo :: {-# UNPACK #-} !SeqInfo
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
  def = Packet def mempty
  {-# INLINE CONLIKE def #-}

-- | Does this packet carry a terminal 'SeqInfo'?
--
-- @since 1.0.0
isPktTerminal :: Packet -> Bool
isPktTerminal pkt = pktSeqInfo pkt == SeqTerm

-- -----------------------------------------------------------------------------
--
-- 'Packet' Sequencing
--

-- | 'SeqInfo' is an unsigned integer with 31-bits of precision used for
-- ordering sequences of 'Packet's.
--
-- @since 1.0.0
data SeqInfo
  = SeqInfo {-# UNPACK #-} !Word32
  | SeqTerm
  deriving stock (Eq, Generic, Show)

-- | @since 1.0.0
instance Ord SeqInfo where
  compare = compare `on` toSeqIx
  {-# INLINE compare #-}

  (<=) = (<=) `on` toSeqIx
  {-# INLINE (<=) #-}

-- | @since 1.0.0
instance Bounded SeqInfo where
  minBound = SeqTerm
  {-# INLINE CONLIKE minBound #-}

  -- 'SeqInfo' reserves the least significant bit in the 'Word32' for
  -- encoding.
  maxBound = SeqInfo (maxBound - 1)
  {-# INLINE CONLIKE maxBound #-}

-- | prop> def@ SeqInfo == SeqTerm
--
-- @since 1.0.0
instance HasDefault SeqInfo where
  def = SeqTerm
  {-# INLINE CONLIKE def #-}

-- | @
-- message SeqInfo {
--   uint32 index = 1;
-- }
-- @
--
-- @since 1.0.0
instance MessageField SeqInfo where
  encodeMessageField n = Wire.Encode.uint32 n . toSeqIx

  decodeMessageField = fromSeqIx <$> Wire.Decode.one Wire.Decode.uint32 0

  protoType _ = DotProtoField 1 (Prim UInt32) (Single "index") [] ""

-- | Is this 'SeqInfo' terminal @(== SeqTerm)@?
--
-- @since 1.0.0
isSeqTerminal :: SeqInfo -> Bool
isSeqTerminal info = info == SeqTerm

-- | TODO:
--
-- @since 1.0.0
toSeqIx :: SeqInfo -> Word32
toSeqIx (SeqInfo i) = 1 + i
toSeqIx SeqTerm = 0

-- | TODO:
--
-- @since 1.0.0
fromSeqIx :: Word32 -> SeqInfo
fromSeqIx 0 = SeqTerm
fromSeqIx i = SeqInfo (i - 1)
