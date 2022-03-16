{-# OPTIONS_GHC -Wno-orphans #-}

module Network.GRPC.HighLevel.Orphans () where

import Data.Map qualified as Map
import Data.Vector qualified as Vector
import GHC.Exts (Proxy#, proxy#)

-- grpc-haskell -----
import Network.GRPC.HighLevel (MetadataMap (MetadataMap, unMap))

-- proto3-suite -----
import Proto3.Suite
  ( DotProtoField (DotProtoField),
    DotProtoIdentifier (Single),
    DotProtoPrimType (Named),
    DotProtoType (Repeated),
    HasDefault (def, isDefault),
    Message (decodeMessage, dotProto, encodeMessage),
    MessageField (decodeMessageField, encodeMessageField, protoType),
    Named (nameOf),
    UnpackedVec (UnpackedVec, unpackedvec),
  )

-- proto3-wire -----
import Proto3.Wire.Decode qualified as Wire.Decode
import Proto3.Wire.Encode qualified as Wire.Encode

-- grpc-mqtt -----
import Network.GRPC.MQTT.Wrap.Core (Wrap)

-- -----------------------------------------------------------------------------

-- | >>> nameOf (proxy# :: Proxy# MetadataMap)
--   "MetadataMap"
--
-- @since 1.0.0
instance Named MetadataMap where
  nameOf _ = "MetadataMap"
  {-# INLINE CONLIKE nameOf #-}

-- | prop> def @MetadataMap == MetadataMap Map.empty
--
-- @since 1.0.0
instance HasDefault MetadataMap where
  def = MetadataMap Map.empty
  {-# INLINE CONLIKE def #-}

  isDefault = Map.null . unMap

-- | Orphan 'MessageField' instance for 'MetadataMap'.
--
-- @
-- message MetadataMap {
--   message Entry {
--     bytes key = 1;
--     repeated bytes value = 2;
--   }
--   repeated Entry fields = 1;
-- }
-- @
--
-- @since 1.0.0
instance MessageField MetadataMap where
  encodeMessageField n (MetadataMap kvs) =
    let entries :: [MetadataEntry]
        entries = Map.foldrWithKey (\k -> (:) . mkMetadataEntry k) [] kvs
     in foldMap (Wire.Encode.embedded n . encodeMessage 1) entries

  decodeMessageField =
    Wire.Decode.repeated (Wire.Decode.embedded' (decodeMessage 1))
      <&> foldr (uncurry Map.insert . fromMetadataEntry) Map.empty
      <&> MetadataMap

  protoType _ =
    let entryNm = nameOf (proxy# :: Proxy# MetadataEntry)
        entryTy = Named (Single entryNm)
     in DotProtoField 1 (Repeated entryTy) (Single "fields") [] ""

-- | @since 1.0.0
instance Message MetadataMap where
  encodeMessage _ = Wire.Encode.embedded 1 . encodeMessageField 1

  decodeMessage _ = Wire.Decode.at decodeMessageField 1

  dotProto _ = [] -- FIXME:
  {-# INLINE CONLIKE dotProto #-}

-- -----------------------------------------------------------------------------

-- | 'MetadataEntry' is the protobuf representation an entry in a 'MetadataMap'.
--
-- @
-- message Entry {
--   bytes key = 1;
--   repeated bytes value = 2;
-- }
-- @
--
-- @since 1.0.0
data MetadataEntry = MetadataEntry ByteString (UnpackedVec ByteString)
  deriving stock (Eq, Generic, Show)
  deriving anyclass Message

-- | @since 1.0.0
instance Named MetadataEntry where
  nameOf _ = "MetadataEntry"
  {-# INLINE CONLIKE nameOf #-}

-- | Constructs a 'MetadataEntry' from its key-value pair.
--
-- @since 1.0.0
mkMetadataEntry :: ByteString -> [ByteString] -> MetadataEntry
mkMetadataEntry k v = MetadataEntry k (UnpackedVec (Vector.fromList v))

-- | Deconstructs a 'MetadataEntry' into its key-value pair.
--
-- @since 1.0.0
fromMetadataEntry :: MetadataEntry -> (ByteString, [ByteString])
fromMetadataEntry (MetadataEntry k v) = (k, Vector.toList (unpackedvec v))
