-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE ImportQualifiedPost #-}

-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.Request
  ( -- * MQTT Requests
    Request (Request),
    rqtMessage,
    rqtTimeout,
    rqtMetadata,

    -- * Wire Format
    wireUnwrapRequest,
    wireDecodeRequest,
    wireWrapRequest,
    wireEncodeRequest,
  )
where

-- -----------------------------------------------------------------------------

import Network.GRPC.HighLevel (MetadataMap)
import Network.GRPC.HighLevel.Client (TimeoutSeconds)

import Proto3.Suite (Message, fromByteString, toLazyByteString)
import Proto3.Wire.Decode qualified as Wire (Parser (Parser))
import Proto3.Wire.Decode qualified as Wire.Decode
import Proto3.Wire.Encode qualified as Wire (MessageBuilder)
import Proto3.Wire.Encode qualified as Wire.Encode

-- -----------------------------------------------------------------------------

import Network.GRPC.HighLevel.Extra
  ( wireDecodeMetadataMap,
    wireEncodeMetadataMap,
  )

-- -----------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
data Request rqt = Request
  { rqtMessage :: rqt
  , rqtTimeout :: TimeoutSeconds
  , rqtMetadata :: MetadataMap
  }
  deriving stock (Eq, Generic, Show)

-- | @since 1.0.0
instance Functor Request where
  fmap f (Request x to ms) = Request (f x) to ms
  {-# INLINE fmap #-}

-- | TODO
--
-- @since 1.0.0
wireUnwrapRequest :: Wire.Parser Wire.Decode.RawMessage (Request ByteString)
wireUnwrapRequest =
  Request
    <$> Wire.Decode.at (Wire.Decode.one Wire.Decode.byteString mempty) 1
    <*> (fromIntegral <$> Wire.Decode.at (Wire.Decode.one Wire.Decode.sint64 maxBound) 2)
    <*> Wire.Decode.at wireDecodeMetadataMap 3

-- | TODO
--
-- @since 1.0.0
wireDecodeRequest :: Message rqt => Wire.Parser Wire.Decode.RawMessage (Request rqt)
wireDecodeRequest = do
  Request bytes timeout metadata <- wireUnwrapRequest
  case fromByteString bytes of
    Left perr -> Wire.Parser \_ -> Left perr
    Right msg -> pure (Request msg timeout metadata)

-- pure (Request (fromMaybe mempty rqt) (fromIntegral timeout) metadata)

-- | TODO
--
-- @since 1.0.0
wireWrapRequest :: Request ByteString -> Wire.MessageBuilder
wireWrapRequest Request{..} =
  Wire.Encode.byteString 1 rqtMessage
    <> Wire.Encode.sint64 2 (fromIntegral rqtTimeout)
    <> wireEncodeMetadataMap 3 rqtMetadata

-- | TODO
--
-- @since 1.0.0
wireEncodeRequest :: Message rqt => Request rqt -> Wire.MessageBuilder
wireEncodeRequest = wireWrapRequest . fmap (toStrict . toLazyByteString)
