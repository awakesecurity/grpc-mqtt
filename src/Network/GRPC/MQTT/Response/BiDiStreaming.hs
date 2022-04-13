-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE ImportQualifiedPost #-}

-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.Response.BiDiStreaming
  ( -- * MQTT ClientStreaming Responses
    BiDiStreamingResponse (BiDiStreamingResponse),
    rspMetadata,
    rspStatusCode,
    rspStatusDetails,

    -- * Wire Format
    wireEncodeBiDiStreamingResponse,
    wireDecodeBiDiStreamingResponse,

    -- * Conversion
    fromBiDiStreamingResult,
    toBiDiStreamingResult,
  )
where

import Network.GRPC.HighLevel.Client
  ( ClientError,
    ClientResult (ClientErrorResponse, ClientBiDiResponse),
    GRPCMethodType (BiDiStreaming),
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
import Network.GRPC.MQTT.Response.ServerStreaming
  ( ServerStreamingResponse (ServerStreamingResponse)
  )
import Network.GRPC.MQTT.Response.ServerStreaming qualified as Response.ServerStreaming

-- -----------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
newtype BiDiStreamingResponse = MkBiDiStreamingResponse
  {getBiDiStreamingResponse :: ServerStreamingResponse}
  deriving stock (Eq, Generic, Show)

pattern BiDiStreamingResponse ::
  MetadataMap ->
  StatusCode ->
  StatusDetails ->
  BiDiStreamingResponse
pattern BiDiStreamingResponse {rspMetadata, rspStatusCode, rspStatusDetails} =
  MkBiDiStreamingResponse
    ( ServerStreamingResponse
        rspMetadata
        rspStatusCode
        rspStatusDetails
    )

-- -----------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
wireEncodeBiDiStreamingResponse ::
  BiDiStreamingResponse ->
  Wire.MessageBuilder
wireEncodeBiDiStreamingResponse =
  coerce Response.ServerStreaming.wireEncodeServerStreamingResponse

-- | TODO
--
-- @since 1.0.0
wireDecodeBiDiStreamingResponse ::
  Wire.Parser Wire.RawMessage BiDiStreamingResponse
wireDecodeBiDiStreamingResponse =
  coerce Response.ServerStreaming.wireDecodeServerStreamingResponse

-- -----------------------------------------------------------------------------
--
-- Conversion
--

-- | TODO
--
-- @since 1.0.0
fromBiDiStreamingResult ::
  ClientResult 'BiDiStreaming a ->
  Either ClientError BiDiStreamingResponse
fromBiDiStreamingResult (ClientErrorResponse err) = Left err
fromBiDiStreamingResult (ClientBiDiResponse ms sc sd) =
  Right $
    BiDiStreamingResponse
      { rspMetadata = ms
      , rspStatusCode = sc
      , rspStatusDetails = coerce sd
      }

-- | TODO
--
-- @since 1.0.0
toBiDiStreamingResult ::
  BiDiStreamingResponse ->
  ClientResult 'BiDiStreaming a
toBiDiStreamingResult rsp =
  ClientBiDiResponse
    (rspMetadata rsp)
    (rspStatusCode rsp)
    (coerce (rspStatusDetails rsp))
