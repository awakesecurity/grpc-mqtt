-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE ImportQualifiedPost #-}

-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.Response
  ( -- * MQTT Responses
    Response (Response),
    rspMessage,
    rspInitMetadata,
    rspPostMetadata,
    rspStatusCode,
    rspStatusDetails,

    -- * Wire Format
    wireEncodeResponse,
    wireWrapResponse,
    wireUnwrapResponse,
    wireDecodeResponse,

    -- * Conversion
    fromClientResult,
    toClientResult,
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
data Response rsp = Response
  { rspMessage :: rsp
  , rspInitMetadata :: MetadataMap
  , rspPostMetadata :: MetadataMap
  , rspStatusCode :: StatusCode
  , rspStatusDetails :: ByteString
  }
  deriving stock (Eq, Generic, Show)

-- | @since 1.0.0
instance Functor Response where
  fmap f (Response x ms0 ms1 sc sd) = Response (f x) ms0 ms1 sc sd
  {-# INLINE fmap #-}

-- -----------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
wireEncodeResponse :: Message rsp => Response rsp -> Wire.MessageBuilder
wireEncodeResponse = wireWrapResponse . fmap (toStrict . Proto3.toLazyByteString)

-- | TODO
--
-- @since 1.0.0
wireWrapResponse :: Response ByteString -> Wire.MessageBuilder
wireWrapResponse rsp =
  Wire.Encode.byteString 1 (rspMessage rsp)
    <> wireEncodeMetadataMap 2 (rspInitMetadata rsp)
    <> wireEncodeMetadataMap 3 (rspPostMetadata rsp)
    <> wireEncodeStatusCode 4 (rspStatusCode rsp)
    <> wireEncodeStatusDetails 5 (coerce $ rspStatusDetails rsp)

-- | TODO
--
-- @since 1.0.0
wireDecodeResponse :: Message a => Wire.Parser Wire.RawMessage (Response a)
wireDecodeResponse = do
  Response bytes ms0 ms1 sc sd <- wireUnwrapResponse
  case Proto3.fromByteString bytes of
    Left perr -> Wire.Parser \_ -> Left perr
    Right msg -> pure (Response msg ms0 ms1 sc sd)

-- | TODO
--
-- @since 1.0.0
wireUnwrapResponse :: Wire.Parser Wire.RawMessage (Response ByteString)
wireUnwrapResponse = do
  Response
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
fromClientResult :: ClientResult 'Normal a -> Either ClientError (Response a)
fromClientResult (ClientErrorResponse err) = Left err
fromClientResult (ClientNormalResponse x ms0 ms1 code details) =
  Right $
    Response
      { rspMessage = x
      , rspInitMetadata = ms0
      , rspPostMetadata = ms1
      , rspStatusCode = code
      , rspStatusDetails = coerce details
      }

-- | TODO
--
-- @since 1.0.0
toClientResult :: Response a -> ClientResult 'Normal a
toClientResult rsp =
  ClientNormalResponse
    (rspMessage rsp)
    (rspInitMetadata rsp)
    (rspPostMetadata rsp)
    (rspStatusCode rsp)
    (coerce (rspStatusDetails rsp))
