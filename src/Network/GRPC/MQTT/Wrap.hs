{-# OPTIONS_GHC -Wno-orphans #-}

-- |
module Network.GRPC.MQTT.Wrap
  ( -- * Wrap Monad
    Wrap,
    unwrap,

    -- ** Construction
    pattern WrapEither,
    pattern WrapRight,
    pattern WrapError,
    emptyWrapError,

    -- * Wrap Transformer
    WrapT (WrapT, unwrapT),
    hoistWrapT,

    -- * Wrapping
    readStream,
    readMetadataMap,
    fromLazyByteString,
    parseErrorToRCE,
  )
where

import Data.Traversable (for)
import Data.Vector (Vector)
import Network.GRPC.HighLevel (MetadataMap)

-- proto3-suite -----
import Proto3.Suite
  ( Enumerated (Enumerated),
    Message,
    decodeMessage,
    fromByteString,
  )

-- proto3-wire -----
import Proto3.Wire.Decode (ParseError (BinaryError, EmbeddedError, WireTypeError))
import Proto3.Wire.Decode qualified as Wire.Decode

-- grpc-mqtt -----
import Network.GRPC.MQTT.Wrap.Core
  ( Wrap,
    WrapT (WrapT, unwrapT),
    unwrap,
    hoistWrapT,
    pattern WrapEither,
    pattern WrapError,
    pattern WrapRight,
  )
import Network.GRPC.MQTT.Wrap.Stream (getStream)
import Proto.Mqtt
  ( RError
      ( RErrorNoParseBinary,
        RErrorNoParseEmbedded,
        RErrorNoParseWireType,
        RErrorUnknownError
      ),
    RemoteError (RemoteError),
    RemoteErrorExtra (RemoteErrorExtraEmbeddedError),
  )

--------------------------------------------------------------------------------

-- | An empty 'Wrap' error, using 'RErrorUnknownError'.
emptyWrapError :: Wrap a
emptyWrapError = WrapError (RemoteError (Enumerated (Right RErrorUnknownError)) mempty Nothing)

-- | TODO: docs
readStream :: Message a => LByteString -> Wrap (Vector a)
readStream msg = do
  stream <- join (fromLazyByteString msg)
  for (getStream stream) \chunk ->
    case fromByteString chunk of
      Left err -> WrapError (parseErrorToRCE err)
      Right rsp -> WrapRight rsp

readMetadataMap :: ByteString -> Wrap MetadataMap
readMetadataMap bytes =
  case Wire.Decode.parse (decodeMessage 0) bytes of
    Left err -> WrapError (parseErrorToRCE err)
    Right xs -> WrapRight xs

-- | TODO: docs
fromLazyByteString :: Message a => LByteString -> Wrap a
fromLazyByteString msg =
  case fromByteString (toStrict msg) of
    Left err -> WrapError (parseErrorToRCE err)
    Right xs -> WrapRight xs

-- FIXME:
parseErrorToRCE :: ParseError -> RemoteError
parseErrorToRCE (WireTypeError txt) = RemoteError (Enumerated (Right RErrorNoParseWireType)) txt Nothing
parseErrorToRCE (BinaryError txt) = RemoteError (Enumerated (Right RErrorNoParseBinary)) txt Nothing
parseErrorToRCE (EmbeddedError txt m_pe) =
  RemoteError
    (Enumerated (Right RErrorNoParseEmbedded))
    txt
    (RemoteErrorExtraEmbeddedError . parseErrorToRCE <$> m_pe)
