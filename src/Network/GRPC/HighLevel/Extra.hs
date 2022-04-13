-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TypeApplications #-}

-- | This module exports proto3-wire encoders and parsers for grpc-haskell
-- types.
--
-- @since 1.0.0
module Network.GRPC.HighLevel.Extra
  ( -- * MetadataMap
    wireDecodeMetadataMap,
    wireEncodeMetadataMap,
    wireDecodeMetadataEntry,

    -- * StatusCode
    wireEncodeStatusCode,
    wireDecodeStatusCode,
    mkStatusCode,

    -- * StatusDetails
    wireEncodeStatusDetails,
    wireDecodeStatusDetails,
  )
where

import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Vector qualified as Vector

import Network.GRPC.HighLevel
  ( MetadataMap (MetadataMap),
    StatusCode
      ( StatusAborted,
        StatusAlreadyExists,
        StatusCancelled,
        StatusDataLoss,
        StatusDeadlineExceeded,
        StatusFailedPrecondition,
        StatusInternal,
        StatusInvalidArgument,
        StatusNotFound,
        StatusOk,
        StatusOutOfRange,
        StatusPermissionDenied,
        StatusResourceExhausted,
        StatusUnauthenticated,
        StatusUnavailable,
        StatusUnimplemented,
        StatusUnknown
      ),
    StatusDetails (StatusDetails),
  )

import Proto3.Suite (UnpackedVec (UnpackedVec), encodeMessage)
import Proto3.Wire (FieldNumber)
import Proto3.Wire.Decode qualified as Wire (Parser, RawField, RawMessage)
import Proto3.Wire.Decode qualified as Wire.Decode
import Proto3.Wire.Encode qualified as Wire (MessageBuilder)
import Proto3.Wire.Encode qualified as Wire.Encode

-- -----------------------------------------------------------------------------
--
-- Wire encoders/decoders for grpc-haskell 'MetadataMap'
--

-- | Proto wire decoder for metadata maps.
--
-- @since 1.0.0
wireDecodeMetadataMap :: Wire.Parser Wire.RawField MetadataMap
wireDecodeMetadataMap =
  coerce @(Map ByteString [ByteString]) @MetadataMap . Map.fromList
    <$> Wire.Decode.repeated (Wire.Decode.embedded' $ wireDecodeMetadataEntry 1)

-- | Proto wire encoder for metadata maps.
--
-- @since 1.0.0
wireEncodeMetadataMap :: FieldNumber -> MetadataMap -> Wire.MessageBuilder
wireEncodeMetadataMap n (MetadataMap kvs) =
  let entries :: [(ByteString, [ByteString])]
      entries = Map.foldrWithKey (\k v xs -> (k, v) : xs) [] kvs
   in foldMap (Wire.Encode.embedded n . wireEncodeMetadataEntry 1) entries

-- | Proto wire decoder for a single entry within a 'MetadataMap'.
--
-- @since 1.0.0
wireDecodeMetadataEntry ::
  FieldNumber ->
  Wire.Parser Wire.RawMessage (ByteString, [ByteString])
wireDecodeMetadataEntry = Wire.Decode.at do
  key <- Wire.Decode.one Wire.Decode.byteString ByteString.empty
  val <- Wire.Decode.repeated Wire.Decode.byteString
  pure (key, val)

-- | Proto wire encoder for a single entry within a 'MetadataMap'.
--
-- @since 1.0.0
wireEncodeMetadataEntry :: FieldNumber -> (ByteString, [ByteString]) -> Wire.MessageBuilder
wireEncodeMetadataEntry n (k, vs) = encodeMessage n (k, UnpackedVec (Vector.fromList vs))

-- -----------------------------------------------------------------------------
--
-- Wire encoders/decoders for grpc-haskell 'StatusCode'
--

-- | Proto wire encoder for gRPC status codes.
--
-- @since 1.0.0
wireEncodeStatusCode :: FieldNumber -> StatusCode -> Wire.MessageBuilder
wireEncodeStatusCode n code =
  Wire.Encode.sfixed32 n (fromIntegral @Int @Int32 $ fromEnum code)

-- | Proto wire decoder for gRPC status codes. Unknown status codes will yield
-- the 'StatusUnknown' enum.
--
-- @since 1.0.0
wireDecodeStatusCode :: Wire.Parser Wire.RawField StatusCode
wireDecodeStatusCode =
  let unknown32 :: Int32
      unknown32 = fromIntegral (fromEnum StatusUnknown)
   in fmap mkStatusCode (Wire.Decode.one Wire.Decode.sfixed32 unknown32)

-- | Safe alternative to 'toEnum' for 'StatusCode'. All unknown status code
-- numbers are sent yield the 'StatusUnknown' enum.
--
-- >>> mkStatusCode 0
-- StatusOk
--
-- >>> mkStatusCode 1337 -- invalid gRPC status code
-- StatusUnknown
--
-- @since 1.0.0
mkStatusCode :: (Eq a, Num a) => a -> StatusCode
mkStatusCode n
  | n == 0 = StatusOk
  | n == 1 = StatusCancelled
  | n == 2 = StatusUnknown
  | n == 3 = StatusInvalidArgument
  | n == 4 = StatusDeadlineExceeded
  | n == 5 = StatusNotFound
  | n == 6 = StatusAlreadyExists
  | n == 7 = StatusPermissionDenied
  | n == 8 = StatusResourceExhausted
  | n == 9 = StatusFailedPrecondition
  | n == 10 = StatusAborted
  | n == 11 = StatusOutOfRange
  | n == 12 = StatusUnimplemented
  | n == 13 = StatusInternal
  | n == 14 = StatusUnavailable
  | n == 15 = StatusDataLoss
  | n == 16 = StatusUnauthenticated
  | otherwise = StatusUnknown

-- -----------------------------------------------------------------------------
--
-- Wire encoders/decoders for grpc-haskell 'StatusDetails'
--

-- | Proto wire encoder for gRPC status details.
--
-- @since 1.0.0
wireEncodeStatusDetails :: FieldNumber -> StatusDetails -> Wire.MessageBuilder
wireEncodeStatusDetails n =
  coerce
    @(ByteString -> Wire.MessageBuilder)
    @(StatusDetails -> Wire.MessageBuilder)
    (Wire.Encode.byteString n)

-- | Proto wire decoder for gRPC status details.
--
-- @since 1.0.0
wireDecodeStatusDetails :: Wire.Parser Wire.RawField StatusDetails
wireDecodeStatusDetails =
  coerce
    @(Wire.Parser Wire.RawField ByteString)
    @(Wire.Parser Wire.RawField StatusDetails)
    (Wire.Decode.one Wire.Decode.byteString ByteString.empty)
