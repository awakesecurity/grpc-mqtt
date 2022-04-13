-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE ImportQualifiedPost #-}

-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.Response.ClientStreaming
  ( -- * MQTT ClientStreaming Responses
    ClientStreamingResponse (ClientStreamingResponse),
    rspMessage,
    rspInitMetadata,
    rspPostMetadata,
    rspStatusCode,
    rspStatusDetails,

    -- * Wire Format
    wireEncodeClientStreamingResponse,
    wireWrapClientStreamingResponse,
    wireUnwrapClientStreamingResponse,
    wireDecodeClientStreamingResponse,

    -- * Conversion
    fromClientStreamingResult,
    toClientStreamingResult,
  )
where

import Data.Functor.Compose (Compose)

import Network.GRPC.HighLevel.Client
  ( ClientError,
    ClientResult (ClientErrorResponse, ClientWriterResponse),
    GRPCMethodType (ClientStreaming),
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

import Network.GRPC.MQTT.Response.Normal (NormalResponse (NormalResponse))
import Network.GRPC.MQTT.Response.Normal qualified as Response.Normal

-- -----------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
newtype ClientStreamingResponse rsp = MkClientStreamingResponse
  {getClientStreamingResponse :: NormalResponse (Maybe rsp)}
  deriving stock (Eq, Generic, Show)
  deriving (Functor) via (Compose NormalResponse Maybe)

-- | TODO
--
-- @since 1.0.0
pattern ClientStreamingResponse ::
  Maybe rsp ->
  MetadataMap ->
  MetadataMap ->
  StatusCode ->
  ByteString ->
  ClientStreamingResponse rsp
pattern ClientStreamingResponse
  {rspMessage, rspInitMetadata, rspPostMetadata, rspStatusCode, rspStatusDetails} =
  MkClientStreamingResponse
    ( NormalResponse
        rspMessage
        rspInitMetadata
        rspPostMetadata
        rspStatusCode
        rspStatusDetails
    )

-- -----------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
wireEncodeClientStreamingResponse ::
  forall a.
  Message a =>
  ClientStreamingResponse a ->
  Wire.MessageBuilder
wireEncodeClientStreamingResponse =
  Response.Normal.wireWrapNormalResponse
    . fmap (maybe mempty (toStrict . Proto3.toLazyByteString))
    . getClientStreamingResponse

-- | TODO
--
-- @since 1.0.0
wireWrapClientStreamingResponse ::
  ClientStreamingResponse ByteString ->
  Wire.MessageBuilder
wireWrapClientStreamingResponse =
  Response.Normal.wireWrapNormalResponse
    . fmap (fromMaybe (mempty @ByteString))
    . getClientStreamingResponse

-- | TODO
--
-- @since 1.0.0
wireDecodeClientStreamingResponse ::
  forall a.
  Message a =>
  Wire.Parser Wire.RawMessage (ClientStreamingResponse a)
wireDecodeClientStreamingResponse = do
  normal <- Response.Normal.wireDecodeNormalResponse
  pure (MkClientStreamingResponse (fmap Just normal))

-- | TODO
--
-- @since 1.0.0
wireUnwrapClientStreamingResponse ::
  Wire.Parser Wire.RawMessage (ClientStreamingResponse ByteString)
wireUnwrapClientStreamingResponse = do
  x <- Response.Normal.wireUnwrapNormalResponse
  pure (MkClientStreamingResponse (fmap Just x))

-- -----------------------------------------------------------------------------
--
-- Conversion
--

-- | TODO
--
-- @since 1.0.0
fromClientStreamingResult ::
  ClientResult 'ClientStreaming a ->
  Either ClientError (ClientStreamingResponse a)
fromClientStreamingResult (ClientErrorResponse err) = Left err
fromClientStreamingResult (ClientWriterResponse x ms0 ms1 code details) =
  Right $
    ClientStreamingResponse
      { rspMessage = x
      , rspInitMetadata = ms0
      , rspPostMetadata = ms1
      , rspStatusCode = code
      , rspStatusDetails = coerce details
      }

-- | TODO
--
-- @since 1.0.0
toClientStreamingResult ::
  ClientStreamingResponse a ->
  ClientResult 'ClientStreaming a
toClientStreamingResult rsp =
  ClientWriterResponse
    (rspMessage rsp)
    (rspInitMetadata rsp)
    (rspPostMetadata rsp)
    (rspStatusCode rsp)
    (coerce (rspStatusDetails rsp))
