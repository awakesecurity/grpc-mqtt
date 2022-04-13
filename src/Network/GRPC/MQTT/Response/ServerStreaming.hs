-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE ImportQualifiedPost #-}

-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.Response.ServerStreaming
  ( -- * MQTT ClientStreaming Responses
    ServerStreamingResponse (ServerStreamingResponse),
    rspMetadata,
    rspStatusCode,
    rspStatusDetails,

    -- * Wire Format
    wireEncodeServerStreamingResponse,
    wireDecodeServerStreamingResponse,

    -- * Conversion
    fromServerStreamingResult,
    toServerStreamingResult,
  )
where

import Data.Functor.Compose (Compose)

import Network.GRPC.HighLevel.Client
  ( ClientError,
    ClientResult (ClientErrorResponse, ClientReaderResponse),
    GRPCMethodType (ServerStreaming),
    MetadataMap,
    StatusCode,
    StatusDetails (StatusDetails),
  )

import Proto3.Suite (Message, Nested (Nested))
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
data ServerStreamingResponse = ServerStreamingResponse
  { rspMetadata :: MetadataMap
  , rspStatusCode :: StatusCode
  , rspStatusDetails :: StatusDetails
  }
  deriving stock (Eq, Generic, Show)

-- -----------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
wireEncodeServerStreamingResponse ::
  ServerStreamingResponse ->
  Wire.MessageBuilder
wireEncodeServerStreamingResponse rsp =
  wireEncodeMetadataMap 1 (rspMetadata rsp)
    <> wireEncodeStatusCode 2 (rspStatusCode rsp)
    <> wireEncodeStatusDetails 3 (coerce $ rspStatusDetails rsp)

-- | TODO
--
-- @since 1.0.0
wireDecodeServerStreamingResponse ::
  Wire.Parser Wire.RawMessage ServerStreamingResponse
wireDecodeServerStreamingResponse = do
  ServerStreamingResponse
    <$> Wire.Decode.at wireDecodeMetadataMap 1
    <*> Wire.Decode.at wireDecodeStatusCode 2
    <*> Wire.Decode.at (coerce wireDecodeStatusDetails) 3

-- -----------------------------------------------------------------------------
--
-- Conversion
--

-- | TODO
--
-- @since 1.0.0
fromServerStreamingResult ::
  ClientResult 'ServerStreaming a ->
  Either ClientError ServerStreamingResponse
fromServerStreamingResult (ClientErrorResponse err) = Left err
fromServerStreamingResult (ClientReaderResponse ms sc sd) =
  Right $
    ServerStreamingResponse
      { rspMetadata = ms
      , rspStatusCode = sc
      , rspStatusDetails = coerce sd
      }

-- | TODO
--
-- @since 1.0.0
toServerStreamingResult ::
  ServerStreamingResponse ->
  ClientResult 'ServerStreaming a
toServerStreamingResult rsp =
  ClientReaderResponse
    (rspMetadata rsp)
    (rspStatusCode rsp)
    (coerce (rspStatusDetails rsp))
