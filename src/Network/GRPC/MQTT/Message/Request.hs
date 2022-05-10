{-# LANGUAGE ImplicitPrelude #-}

-- | The MQTT 'Request' wrapper type.
--
-- @since 1.0.0
module Network.GRPC.MQTT.Message.Request
  ( -- * Requests
    Request (Request, rqtPayload, rqtTimeout, rqtMetadata),

    -- * Wire Encoding
    -- $wire-encoding
    wireEncodeRequest,
    wireWrapRequest,
    wireUnwrapRequest,
  )
where

---------------------------------------------------------------------------------

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as Lazy (ByteString)
import Data.ByteString.Lazy qualified as Lazy.ByteString
import Data.Text.Lazy qualified as Lazy (Text)

import GHC.Generics (Generic)

import Network.GRPC.HighLevel (MetadataMap)

import Proto3.Suite (Message, toLazyByteString)

import Proto3.Wire.Decode qualified as Wire
  ( ParseError (EmbeddedError),
    Parser,
    RawMessage,
  )
import Proto3.Wire.Decode qualified as Decode
import Proto3.Wire.Encode qualified as Encode
import Proto3.Wire.Encode qualified as Wire (MessageBuilder)

---------------------------------------------------------------------------------

import Network.GRPC.HighLevel.Extra
  ( decodeMetadataMap,
    encodeMetadataMap,
  )

-- MQTT Requests ----------------------------------------------------------------

-- | 'Request' is a protobuf message wrapper that carries a message payload,
-- typically a raw bytestring of the encoded 'Message' instance, while being
-- transmitted to the remote client.
--
-- @since 1.0.0
data Request a = Request
  { -- | The request body.
    rqtPayload :: a
  , -- | The timeout duration for the request to be handled in unit seconds.
    rqtTimeout :: {-# UNPACK #-} !Int
  , -- | The metadata attached to a request.
    rqtMetadata :: MetadataMap
  }
  deriving stock (Eq, Generic, Show)

-- | @since 1.0.0
instance Functor Request where
  fmap f (Request x t ms) = Request (f x) t ms
  {-# INLINE fmap #-}

-- Wire Encoding ----------------------------------------------------------------

-- $wire-encoding
--
-- Facilities for encoding and decoding a 'Request' from the wire protobuf binary
-- format.
--
-- When using the proto-wire encoding and decoding functions for 'Request', keep
-- in mind that remote client can never have knowledge of the 'Message' instance
-- for the body of a 'Request'. This means that while you can freely encode
-- requests (via 'wireEncodeRequest') on the client, you can never write a useful
-- implementation for the following parser for the remote client:
--
-- @
-- -- bad!
-- wireDecodeRequest :: 'Message' a => 'Wire.Parse' ('Request' a)
-- wireDecodeRequest = ...
-- @
--
-- A 'Request' is intended to transport a raw wire-encoded message (along with
-- some metadata), to the remote client, which only ever needs to know how to
-- decode the metadata and timeout fields of a request. For this, the
-- 'wireUnwrapRequest' function can be used to partially decode a 'Request' while
-- leaving the 'ByteString' request body encoded.

-- | Like 'wireWrapRequest', but handles the encoding the request body 'Message'
-- before encoding the 'Request'.
--
-- prop> wireEncodeRequest ~ wireWrapRequest . toStrict . toLazyByteString
--
-- @since 1.0.0
wireEncodeRequest :: Message a => Request a -> Lazy.ByteString
wireEncodeRequest rqt =
  let wrapped :: Request ByteString
      wrapped = fmap (Lazy.ByteString.toStrict . toLazyByteString) rqt
   in wireWrapRequest wrapped

-- | Encodes a 'Request' that is wrapping a valid proto-wire format 'ByteString'.
-- 'wireEncodeRequest' can be used to handle 'Request' the wrapping and encoding
-- for instances of 'Message'.
--
-- @since 1.0.0
wireWrapRequest :: Request ByteString -> Lazy.ByteString
wireWrapRequest = Encode.toLazyByteString . encoder
  where
    encoder :: Request ByteString -> Wire.MessageBuilder
    encoder (Request payload timeout metadata) =
      Encode.byteString 1 payload
        <> Encode.int64 2 (fromIntegral timeout)
        <> encodeMetadataMap 3 metadata

-- | Parses a 'ByteString' into a 'Request' with a proto-wire encoded request
-- body.
--
-- @since 1.0.0
wireUnwrapRequest :: ByteString -> Either Decode.ParseError (Request ByteString)
wireUnwrapRequest input =
  case Decode.parse parser input of
    Left perr -> Left (wireRequestParseError perr)
    Right rqt -> Right rqt
  where
    parser :: Wire.Parser Wire.RawMessage (Request ByteString)
    parser = do
      msg <- Decode.at (Decode.one Decode.byteString mempty) 1
      to <- Decode.at (Decode.one Decode.int64 0) 2
      md <- Decode.at decodeMetadataMap 3
      pure (Request msg (fromIntegral to) md)

---------------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
wireRequestParseError :: Wire.ParseError -> Wire.ParseError
wireRequestParseError err =
  let errMsg :: Lazy.Text
      errMsg = "Network.GRPC.MQTT.Message.Request: could not parse 'Request'."
   in Wire.EmbeddedError errMsg (Just err)
