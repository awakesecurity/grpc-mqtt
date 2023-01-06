
-- |
-- Module      :  Network.GRPC.MQTT.Message
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- This module exports the protobuf message types and wire serialization
-- functions used internally by the library.
--
-- @since 1.0.0
module Network.GRPC.MQTT.Message
  ( -- * Message Types
    Request,
    Packet,

    -- * Remote Error
    RemoteError,

    -- * Wire Encoding
    mapEncodeOptions,
    toWireEncoded,

    -- * Wire Decoding
    mapDecodeOptions,
    fromWireEncoded,

    -- ** Wire Decode Errors
    WireDecodeError (DecodeWireError, DecodeZstdError),
    throwWireError,
    throwZstdError,
    toRemoteError,
  )
where

--------------------------------------------------------------------------------

import Control.Monad.Except (MonadError, throwError)

import Proto3.Suite qualified as Proto3
import Proto3.Suite.Class (Message)

import Proto3.Wire.Decode (ParseError)

import Relude

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Compress (ZstdError)
import Network.GRPC.MQTT.Compress qualified as Compress

import Network.GRPC.MQTT.Message.Packet (Packet)
import Network.GRPC.MQTT.Message.Request.Core (Request)

import Network.GRPC.MQTT.Serial (WireDecodeOptions, WireEncodeOptions)
import Network.GRPC.MQTT.Serial qualified as Serial

import Network.GRPC.MQTT.Wrapping (parseErrorToRCE)

import Proto.Mqtt (RemoteError)

-- Wire Encoding ---------------------------------------------------------------

-- | Apply wire encoding transformations (such as compression) to a serialized
-- 'ByteString'.
--
-- @since 1.0.0
mapEncodeOptions :: WireEncodeOptions -> ByteString -> ByteString
mapEncodeOptions options bytes =
  case Serial.encodeCLevel options of
    Nothing -> bytes
    Just level -> Compress.compress level bytes

-- | Serializes a protobuf message (an instance of 'Message') @a@ according to
-- the 'WireEncodeOptions' provided.
--
-- @since 1.0.0
toWireEncoded :: Message a => WireEncodeOptions -> a -> ByteString
toWireEncoded options x =
  let bytes :: ByteString
      bytes = toStrict (Proto3.toLazyByteString x)
   in mapEncodeOptions options bytes

-- Wire Decoding ---------------------------------------------------------------

-- | Apply wire decoding transformations (such as decompression) to a serialized
-- 'ByteString'.
--
-- @since 1.0.0
mapDecodeOptions ::
  MonadError WireDecodeError m =>
  WireDecodeOptions ->
  ByteString ->
  m ByteString
mapDecodeOptions options bytes
  | Serial.decodeDecompress options =
    case Compress.decompress bytes of
      Left err -> throwZstdError err
      Right bs -> pure bs
  | otherwise = pure bytes

-- | Deserializes a wire encoded 'ByteString' into the expected protobuf message
-- type @a@ according to the 'WireDecodeOptions' provided.
--
-- @since 1.0.0
fromWireEncoded ::
  (MonadError WireDecodeError m, Message a) =>
  WireDecodeOptions ->
  ByteString ->
  m a
fromWireEncoded options bytes = do
  bytes' <- mapDecodeOptions options bytes
  case Proto3.fromByteString bytes' of
    Left err -> throwWireError err
    Right rx -> pure rx

-- Wire Decode Options - Errors ------------------------------------------------

-- | 'WireDecodeError' represents the types of errors that can occur when
-- deserializing a 'ByteString' (in wire format) according to a
-- 'WireDecodeOptions' configuration.
--
-- @since 1.0.0
data WireDecodeError
  = -- | 'DecodeWireError' is emitted when a wire parse error is encountered
    -- when parsing the 'ByteString'.
    DecodeWireError ParseError
  | -- | 'DecodeZstdError' is emitted when a zstandard error is thrown while
    -- decompressing the 'ByteString'.
    DecodeZstdError ZstdError
  deriving stock (Eq, Ord, Show, Typeable)

throwWireError :: MonadError WireDecodeError m => ParseError -> m a
throwWireError err = throwError (DecodeWireError err)

throwZstdError :: MonadError WireDecodeError m => ZstdError -> m a
throwZstdError err = throwError (DecodeZstdError err)

-- | Convert a 'WireDecodeError' into a 'RemoteError'.
--
-- @since 1.0.0
toRemoteError :: WireDecodeError -> RemoteError
toRemoteError (DecodeWireError err) = parseErrorToRCE err
toRemoteError (DecodeZstdError err) = Compress.toRemoteError err
