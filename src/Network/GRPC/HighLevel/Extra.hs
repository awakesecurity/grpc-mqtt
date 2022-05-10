{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | TODO
--
-- @since 1.0.0
module Network.GRPC.HighLevel.Extra
  ( -- * TODO
    wireEncodeMetadataMap,
    wireDecodeMetadataMap,
    encodeMetadataMap,
    decodeMetadataMap,
  )
where

---------------------------------------------------------------------------------

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as Lazy (ByteString)
import Data.Map.Strict qualified as Map
import Data.Vector qualified as Vector

import Network.GRPC.HighLevel (MetadataMap (MetadataMap))

import Proto3.Suite (FieldNumber, UnpackedVec (UnpackedVec), encodeMessage)

import Proto3.Wire.Decode qualified as Decode
import Proto3.Wire.Decode qualified as Wire (Parser, RawField)
import Proto3.Wire.Encode qualified as Encode
import Proto3.Wire.Encode qualified as Wire (MessageBuilder)

-- MetadataMap ------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
wireEncodeMetadataMap :: MetadataMap -> Lazy.ByteString
wireEncodeMetadataMap = Encode.toLazyByteString . encodeMetadataMap 1

-- | TODO
--
-- @since 1.0.0
wireDecodeMetadataMap :: ByteString -> Either Decode.ParseError MetadataMap
wireDecodeMetadataMap = Decode.parse do
  Decode.at decodeMetadataMap 1

-- | TODO
--
-- @since 1.0.0
encodeMetadataMap :: FieldNumber -> MetadataMap -> Wire.MessageBuilder
encodeMetadataMap n (MetadataMap kvs) =
  let entries :: [(ByteString, [ByteString])]
      entries = Map.foldrWithKey (\k v xs -> (k, v) : xs) [] kvs
   in foldMap (Encode.embedded n . wireEncodeMetadataEntry) entries

-- | TODO
--
-- @since 1.0.0
decodeMetadataMap :: Wire.Parser Wire.RawField MetadataMap
decodeMetadataMap = do
  xs <- Decode.repeated wireDecodeMetadataEntry
  pure (MetadataMap (Map.fromList xs))

-- | TODO
--
-- @since 1.0.0
wireEncodeMetadataEntry :: (ByteString, [ByteString]) -> Wire.MessageBuilder
wireEncodeMetadataEntry (k, vs) = encodeMessage 1 (k, UnpackedVec (Vector.fromList vs))

-- | TODO
--
-- @since 1.0.0
wireDecodeMetadataEntry :: Wire.Parser Decode.RawPrimitive (ByteString, [ByteString])
wireDecodeMetadataEntry = Decode.embedded' do
  key <- Decode.at (Decode.one Decode.byteString ByteString.empty) 1
  val <- Decode.at (Decode.repeated Decode.byteString) 2
  pure (key, val)
