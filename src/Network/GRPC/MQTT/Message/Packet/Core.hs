{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | TODO
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Message.Packet.Core
  ( -- * Packet
    Packet (Packet, payload, metadata),

    -- * PacketInfo
    PacketInfo (PacketInfo, position, npackets),
  )
where

---------------------------------------------------------------------------------

import Control.Monad (when)

import Data.Data (Data)
import Data.Typeable (Typeable)

import Data.List qualified as List
import Data.String (fromString)
import Data.Text.Lazy qualified as Lazy.Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Data.Vector.Mutable qualified as MVector

import GHC.Generics (Generic)

import Proto3.Suite.Class
  ( MessageField,
    Named,
    decodeMessageField,
    encodeMessageField,
    nameOf,
    protoType,
  )
import Proto3.Suite.DotProto.AST qualified as Proto3
import Proto3.Wire.Decode (Parser, RawField)
import Proto3.Wire.Decode qualified as Decode
import Proto3.Wire.Encode qualified as Encode

-- ------------------------------------------------------------------------------

import Proto3.Wire.Decode.Extra qualified as Decode

-- Packet -----------------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
data Packet msg = Packet
  { payload :: msg
  , metadata :: {-# UNPACK #-} !PacketInfo
  }
  deriving stock (Eq, Ord, Show)
  deriving stock (Data, Generic, Typeable)

-- | @since 0.1.0.0
instance Functor Packet where
  fmap f (Packet x info) = Packet (f x) info
  {-# INLINE fmap #-}

-- PacketInfo -------------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
data PacketInfo = PacketInfo
  { position :: {-# UNPACK #-} !Int
  , npackets :: {-# UNPACK #-} !Int
  }
  deriving stock (Eq, Ord, Show)
  deriving stock (Data, Generic, Typeable)

-- | @since 0.1.0.0
instance Named PacketInfo where
  nameOf _ = fromString (show ''PacketInfo)
  {-# INLINE nameOf #-}

-- | @since 0.1.0.0
instance MessageField PacketInfo where
  encodeMessageField field info =
    let varints :: Vector Int
        varints = Vector.create do
          vec <- MVector.new 2
          MVector.write vec 0 (position info)
          MVector.write vec 1 (npackets info)
          pure vec
     in Encode.packedVarintsV fromIntegral field varints
  {-# INLINE encodeMessageField #-}

  decodeMessageField = do
    varints <- Decode.one Decode.packedVarints []

    when (length varints < 2) do
      throwMissingPacketInfo (length varints)

    let pos :: Int = varints List.!! 0
        num :: Int = varints List.!! 1
     in pure (PacketInfo pos num)
  {-# INLINE decodeMessageField #-}

  protoType _ = Proto3.DotProtoEmptyField
  {-# INLINE protoType #-}

---------------------------------------------------------------------------------

throwMissingPacketInfo :: Int -> Parser RawField a
throwMissingPacketInfo nfields =
  let count = Lazy.Text.pack (show nfields)
      issue = Decode.BinaryError ("expected 2 varints but got " <> count)
   in Decode.throwE (Decode.wireErrorLabel ''PacketInfo issue)
