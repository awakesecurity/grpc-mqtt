-- | TODO:
--
-- @since 1.0.0
module Network.GRPC.MQTT.Wrap.Stream
  ( -- * Streams
    Stream (Stream, getStream),
  )
where

import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.Exts (IsList (Item, toList))

import Proto3.Suite
  ( DotProtoField (DotProtoField),
    DotProtoIdentifier (Single),
    DotProtoPrimType (Bytes),
    DotProtoType (Repeated),
    HasDefault (def, isDefault),
    Message (decodeMessage, dotProto, encodeMessage),
    MessageField (decodeMessageField, encodeMessageField),
    Named (nameOf),
    UnpackedVec (UnpackedVec, unpackedvec),
  )
import Proto3.Wire.Decode qualified as Wire.Decode

-- imports @instance 'Message' 'MetadataMap'@
import Network.GRPC.HighLevel.Orphans ()

-- -----------------------------------------------------------------------------

-- | TODO: doc
newtype Stream :: Type where
  Stream :: {getStream :: Vector ByteString} -> Stream
  deriving stock (Eq, Ord, Generic, Show)
  deriving (MessageField) via UnpackedVec ByteString

-- | @since 1.0.0
instance IsList Stream where
  type Item Stream = ByteString

  fromList = Stream . Vector.fromList

  toList = Vector.toList . getStream

-- | >>> nameOf (proxy# :: Proxy# Stream)
--   "Stream"
--
-- @since 1.0.0
instance Named Stream where
  nameOf _ = "Stream"
  {-# INLINE CONLIKE nameOf #-}

-- | prop> def @Stream == Stream 'Vector.empty'
--
-- @since 1.0.0
instance HasDefault Stream where
  def = Stream Vector.empty
  {-# INLINE CONLIKE def #-}

  isDefault = Vector.null . getStream

-- | @since 1.0.0
instance Message Stream where
  encodeMessage _ = encodeMessageField 1 . UnpackedVec . getStream

  decodeMessage _ = do
    bss <- Wire.Decode.at decodeMessageField 1
    pure (Stream (unpackedvec bss))

  dotProto _ = [DotProtoField 1 (Repeated Bytes) (Single "chunks") [] ""]
  {-# INLINE CONLIKE dotProto #-}
