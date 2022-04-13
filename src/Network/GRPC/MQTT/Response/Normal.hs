-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE ImportQualifiedPost #-}

-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.Response.Normal
  ( -- * MQTT NormalResponses
    NormalResponse (NormalResponse),
    rspMessage,
    rspInitMetadata,
    rspPostMetadata,
    rspStatusCode,
    rspStatusDetails,

    -- * Wire Format
    wireEncodeNormalResponse,
    wireWrapNormalResponse,
    wireUnwrapNormalResponse,
    wireDecodeNormalResponse,

    -- * Conversion
    fromClientNormalResult,
    toClientNormalResult,
  )
where

import Network.GRPC.HighLevel.Client
  ( ClientError,
    ClientResult (ClientErrorResponse, ClientNormalResponse),
    GRPCMethodType (Normal),
    MetadataMap,
    StatusCode,
    StatusDetails (StatusDetails),
  )

import Proto3.Suite (Message)
import Proto3.Suite qualified as Proto3
import Proto3.Wire.Decode qualified as Wire (Parser (Parser), RawMessage)
import Proto3.Wire.Decode qualified as Wire.Decode
import Proto3.Wire.Encode qualified as Wire (MessageBuilder)
import Proto3.Wire.Encode qualified as Wire.Encode

-- -----------------------------------------------------------------------------

import Network.GRPC.HighLevel.Extra
  ( wireDecodeMetadataMap,
    wireDecodeStatusCode,
    wireDecodeStatusDetails,
    wireEncodeMetadataMap,
    wireEncodeStatusCode,
    wireEncodeStatusDetails,
  )

-- -----------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
data NormalResponse rsp = NormalResponse
  { rspMessage :: rsp
  , rspInitMetadata :: MetadataMap
  , rspPostMetadata :: MetadataMap
  , rspStatusCode :: StatusCode
  , rspStatusDetails :: ByteString
  }
  deriving stock (Eq, Generic, Show)

-- | @since 1.0.0
instance Functor NormalResponse where
  fmap f (NormalResponse x ms0 ms1 sc sd) = NormalResponse (f x) ms0 ms1 sc sd
  {-# INLINE fmap #-}

-- -----------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
wireEncodeNormalResponse ::
  Message rsp =>
  NormalResponse rsp ->
  Wire.MessageBuilder
wireEncodeNormalResponse =
  wireWrapNormalResponse
    . fmap (toStrict . Proto3.toLazyByteString)

-- | TODO
--
-- @since 1.0.0
wireWrapNormalResponse :: NormalResponse ByteString -> Wire.MessageBuilder
wireWrapNormalResponse rsp =
  Wire.Encode.byteString 1 (rspMessage rsp)
    <> wireEncodeMetadataMap 2 (rspInitMetadata rsp)
    <> wireEncodeMetadataMap 3 (rspPostMetadata rsp)
    <> wireEncodeStatusCode 4 (rspStatusCode rsp)
    <> wireEncodeStatusDetails 5 (coerce $ rspStatusDetails rsp)

-- | TODO
--
-- @since 1.0.0
wireDecodeNormalResponse :: Message a => Wire.Parser Wire.RawMessage (NormalResponse a)
wireDecodeNormalResponse = do
  NormalResponse bytes ms0 ms1 sc sd <- wireUnwrapNormalResponse
  case Proto3.fromByteString bytes of
    Left perr -> Wire.Parser \_ -> Left perr
    Right msg -> pure (NormalResponse msg ms0 ms1 sc sd)

-- | TODO
--
-- @since 1.0.0
wireUnwrapNormalResponse :: Wire.Parser Wire.RawMessage (NormalResponse ByteString)
wireUnwrapNormalResponse = do
  NormalResponse
    <$> Wire.Decode.at (Wire.Decode.one Wire.Decode.byteString mempty) 1
    <*> Wire.Decode.at wireDecodeMetadataMap 2
    <*> Wire.Decode.at wireDecodeMetadataMap 3
    <*> Wire.Decode.at wireDecodeStatusCode 4
    <*> Wire.Decode.at (coerce wireDecodeStatusDetails) 5

-- -----------------------------------------------------------------------------
--
-- Conversion
--

-- | TODO
--
-- @since 1.0.0
fromClientNormalResult :: ClientResult 'Normal a -> Either ClientError (NormalResponse a)
fromClientNormalResult (ClientErrorResponse err) = Left err
fromClientNormalResult (ClientNormalResponse x ms0 ms1 code details) =
  Right $
    NormalResponse
      { rspMessage = x
      , rspInitMetadata = ms0
      , rspPostMetadata = ms1
      , rspStatusCode = code
      , rspStatusDetails = coerce details
      }

-- | TODO
--
-- @since 1.0.0
toClientNormalResult :: NormalResponse a -> ClientResult 'Normal a
toClientNormalResult rsp =
  ClientNormalResponse
    (rspMessage rsp)
    (rspInitMetadata rsp)
    (rspPostMetadata rsp)
    (rspStatusCode rsp)
    (coerce (rspStatusDetails rsp))
