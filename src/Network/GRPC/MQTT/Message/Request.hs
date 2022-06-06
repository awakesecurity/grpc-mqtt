{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | Definitions for the 'Request' message type.
--
-- = Request Wire Format
--
-- Requests carry instances of 'Message' corresponding protobuf messages, and
-- similar to a instance of 'Message', can be encoded to and from the proto-wire
-- format. Unlike a typical message however, 'Request' encoding and decoding
-- only makes sense in certain contexts.
--
-- An instance @'Message' 'Request'@ is not provided as a precaution against
-- encoding or decoding 'Requests' outside of situations where it is useful.
-- Furthermore, replacing 'Proto3.Suite.encodeMessage' and
-- 'Proto3.Suite.decodeMessage' is a more restricted encoder-decoder pair
-- 'wireEncodeRequest' and 'wireUnwrapRequest'.
--
-- Below is an explaination for where these functions can be used, and examples
-- of how they're used to prepare requests for the following service definition.
--
-- @
-- syntax = "proto3";
--
-- message SearchRequest { some request fields ... }
--
-- message SearchResponse { some response fields ... }
--
-- service SearchService {
--   rpc Search(SearchRequest) returns (SearchResponse);
-- }
-- @
--
-- = Request Encoding
--
-- The __client is responsible for encoding 'Request'__ into a wire formatted
-- 'ByteString' that will be received and handled by the remote client. When the
-- client is preparing a request for a RPC call, a new 'Request' will be
-- constructed carrying a type corresponding to the protobuf message the RPC is
-- expecting as an argument.This newly constructed 'Request' value packages the
-- client's message, the request properties, and gRPC metadata bound to the
-- request as a single entity that can be transmitted to the remote client.
--
-- === Example
--
-- For the client to prepare a request to call the @Search@ method defined by
-- service @SearchService@ providing the following @SearchRequest@ type - which
-- corresponds to the @SearchRequest@ message - as an argument:
--
-- @
-- -- Generated from the @SearchRequest@ message defined in @search.proto@
-- data SearchRequest = SearchRequest { ... }
--
-- -- an instance to 'Message', for converting to and from wire format;
-- -- defined in proto3-suite package under the module 'Proto3.Suite.Class'.
-- instance Message SearchRequest where
--   ...
-- @
--
-- then the client would construct 'Request' type @Request SearchRequest@, encode
-- the constructed request via 'wireEncodeRequest', and publish the resulting
-- 'ByteString' to remote client.
--
-- = Request Decoding
--
-- The __remote client is responsible for decoding 'Request'__ with the
-- 'wireUnwrapRequest' function. 'wireUnwrapRequest' only partially decodes a
-- 'Request', leaving the enclosed 'message' as the protobuf message originally
-- encoded by the request's sender, since:
--
--   1. The remote client may not have the 'Message' instance necessary for
--      decoding the 'message' in some cases.
--
--   2. Remote client never needs to decode the 'message' wrapped by a request,
--      since it performs the request on behalf of the client.
--
-- === Example
--
-- For the remote client to unwrap a 'Request' and make a call to the @Search@
-- method defined by service @SearchService@, assume the remote client machine
-- has access to a function @callSearchRPC@ which takes a serialized
-- @SearchRequest@ message and performs the search call:
--
-- @
-- -- makes a @Search@ request to the server and yields the a @SearchResponse@
-- -- returned by the server
-- callSearchRPC :: ByteString -> SearchResponse
-- @
--
-- then, the remote client would unwrap a 'Request' that was recieved via
-- 'wireUnwrapRequest':
--
-- >>> let encoded :: ByteString = ... -- the incoming request
-- >>> let request :: Request ByteString = wireUnwrapRequest encoded
--
-- The 'message' field of the unwrap 'Request' now contains serialized
-- @SearchRequest@ sent by the client. The raw 'ByteString' @SearchRequest@
-- message can then be provided to @callSearchRPC@ to complete the request.
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Message.Request
  ( -- * Requests
    Request (Request, message, timeout, metadata),

    -- * Wire Encoding
    -- $request-wire-encoding
    wireEncodeRequest,
    wireEncodeRequest',
    wireWrapRequest,
    wireWrapRequest',
    wireBuildRequest,

    -- * Wire Decoding
    -- $request-wire-Decoding
    wireUnwrapRequest,
    wireParseRequest,
  )
where

---------------------------------------------------------------------------------

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as Lazy (ByteString)
import Data.ByteString.Lazy qualified as Lazy.ByteString

import Network.GRPC.HighLevel (MetadataMap)

import Proto3.Suite (Message, toLazyByteString)

import Proto3.Wire (FieldNumber)
import Proto3.Wire.Decode (ParseError, Parser, RawMessage)
import Proto3.Wire.Decode qualified as Decode
import Proto3.Wire.Encode (MessageBuilder)
import Proto3.Wire.Encode qualified as Encode

---------------------------------------------------------------------------------

import Network.GRPC.HighLevel.Extra (decodeMetadataMap, encodeMetadataMap)

import Network.GRPC.MQTT.Message.Request.Core
  ( Request (Request, message, metadata, timeout),
  )
import Network.GRPC.MQTT.Message.TH (reifyFieldNumber, reifyRecordField)

import Proto3.Wire.Decode.Extra qualified as Decode
import Proto3.Wire.Encode.Extra qualified as Encode
import Proto3.Wire.Types.Extra (RecordField)

-- Wire Format - Encoding -------------------------------------------------------

-- $request-wire-encoding
--
-- Serialization functions for converting a 'Request' message to and from wire
-- format.

-- | Fully serializes a 'Request' wrapping 'Message' type, equivalent to:
--
-- >>> wireEncodeRequest ~ wireWrapRequest . fmap toStrict toLazyByteString
--
-- @since 0.1.0.0
wireEncodeRequest :: forall a. Message a => Request a -> Lazy.ByteString
wireEncodeRequest = wireWrapRequest . wireEncodeMessage
  where
    wireEncodeMessage :: Request a -> Request ByteString
    wireEncodeMessage = fmap (Lazy.ByteString.toStrict . toLazyByteString)

-- | Like 'wireEncodeRequest', but the resulting 'ByteString' is strict.
--
-- @since 0.1.0.0
wireEncodeRequest' :: Message a => Request a -> ByteString
wireEncodeRequest' = Lazy.ByteString.toStrict . wireEncodeRequest

-- | Partially serializes a 'Request' carrying a wire encoded 'ByteString'.
-- If possible, 'wireEncodeRequest' should be used instead.
--
-- If the given request's 'message' is not a valid wire binary, then it is very
-- likely the resulting 'ByteString' can never be decoded.
--
-- @since 0.1.0.0
wireWrapRequest :: Request ByteString -> Lazy.ByteString
wireWrapRequest = Encode.toLazyByteString . wireBuildRequest

-- | Like 'wireWrapRequest', but the resulting 'ByteString' is strict.
--
-- @since 0.1.0.0
wireWrapRequest' :: Request ByteString -> ByteString
wireWrapRequest' = Lazy.ByteString.toStrict . wireWrapRequest

-- | 'MessageBuilder' capable of partially serializing a 'Request'. The wrapped
-- 'message' 'ByteString' __must__ be a valid wire binary.
--
-- @since 0.1.0.0
wireBuildRequest :: Request ByteString -> MessageBuilder
wireBuildRequest rqt =
  wireBuildMessageField
    <> wireBuildTimeoutField
    <> wireBuildMetadataField
  where
    wireBuildMessageField :: MessageBuilder
    wireBuildMessageField =
      let fieldnum :: FieldNumber
          fieldnum = $(reifyFieldNumber ''Request 'message)
       in Encode.byteString fieldnum (message rqt)

    wireBuildTimeoutField :: MessageBuilder
    wireBuildTimeoutField =
      let fieldnum :: FieldNumber
          fieldnum = $(reifyFieldNumber ''Request 'timeout)
       in Encode.sint fieldnum (timeout rqt)

    wireBuildMetadataField :: MessageBuilder
    wireBuildMetadataField =
      let fieldnum :: FieldNumber
          fieldnum = $(reifyFieldNumber ''Request 'metadata)
       in encodeMetadataMap fieldnum (metadata rqt)

-- Wire Format - Decoding -------------------------------------------------------

-- $request-message-parsers
--
-- Wire parsers used to decode a serialized 'Request' message and 'Request'
-- record fields.

-- | Partially decodes a 'Request' message, leaving wrapped 'message' in wire
-- format.
--
-- @since 0.1.0.0
wireUnwrapRequest :: ByteString -> Either ParseError (Request ByteString)
wireUnwrapRequest = Decode.parse wireParseRequest

-- | Parses a serialized 'Request' message.
--
-- @since 0.1.0.0
wireParseRequest :: Parser RawMessage (Request ByteString)
wireParseRequest = do
  payload <- wireParseMessageField
  timeout <- wireParseTimeoutField
  metadata <- wireParseMetadataField
  pure (Request payload timeout metadata)
  where
    wireParseMessageField :: Parser RawMessage ByteString
    wireParseMessageField =
      let recField :: RecordField
          recField = $(reifyRecordField ''Request 'message)
       in Decode.primOptField recField Decode.byteString ByteString.empty

    wireParseTimeoutField :: Parser RawMessage Int
    wireParseTimeoutField =
      let recField :: RecordField
          recField = $(reifyRecordField ''Request 'timeout)
       in Decode.primOneField recField Decode.sint

    wireParseMetadataField :: Parser RawMessage MetadataMap
    wireParseMetadataField =
      let recField :: RecordField
          recField = $(reifyRecordField ''Request 'metadata)
       in Decode.msgOneField recField decodeMetadataMap
