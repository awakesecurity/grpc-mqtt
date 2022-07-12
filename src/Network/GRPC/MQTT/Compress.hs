-- | This module defines a type-safe wrappers over for the zstandard compression
-- functions.
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Compress
  ( -- * Compression
    compress,

    -- * Zstandard Errors
    ZstdError (ZstdError, getZstdError),
    toRemoteError,

    -- * Decompression
    decompress,
  )
where

--------------------------------------------------------------------------------

import Codec.Compression.Zstd qualified as Zstd

import Control.Monad.Except (MonadError, throwError)

import Data.Data (Data)

import Data.ByteString qualified as ByteString

import Proto3.Suite (Enumerated)
import Proto3.Suite qualified as Proto3

import Relude

import Text.Show qualified as Show

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Option.CLevel (CLevel)
import Network.GRPC.MQTT.Option.CLevel qualified as CLevel

import Proto.Mqtt (RError, RemoteError)
import Proto.Mqtt qualified as Proto

-- Compression -----------------------------------------------------------------

-- | Compress the 'ByteString' as a single zstandard frame.
--
-- @since 0.1.0.0
compress :: CLevel -> ByteString -> ByteString
compress level bytes
  | ByteString.null bytes = bytes
  | otherwise = Zstd.compress (CLevel.fromCLevel level) bytes

-- Decompression ---------------------------------------------------------------

-- | 'ZstdError' represent the errors that can be produced during decompression.
-- It is a generic zstandard error string emitted from the zstandard FFI.
--
-- @since 0.1.0.0
newtype ZstdError = ZstdError {getZstdError :: String}
  deriving stock (Data, Eq, Ord, Show, Typeable)

-- | @since 0.1.0.0
instance Exception ZstdError where
  displayException (ZstdError err) =
    Show.showString "zstd decompression error: " err

-- | Convert a 'ZstdError' to a 'RemoteError'.
--
-- @since 0.1.0.0
toRemoteError :: ZstdError -> RemoteError
toRemoteError err =
  let encoded :: Enumerated RError
      encoded = Proto3.Enumerated (Right Proto.RErrorIOGRPCCallInvalidMessage)
   in Proto.RemoteError
        { Proto.remoteErrorErrorType = encoded
        , Proto.remoteErrorMessage = toLText (displayException err)
        , Proto.remoteErrorExtra = Nothing
        }

-- | Decompress a 'ByteString' (compressed via 'compress') as a single
-- zstandard frame.
--
-- A 'ZstdError' is emitted if an error was thrown by the internal zstandard FFI
-- call.
--
-- @since 0.1.0.0
decompress :: MonadError ZstdError m => ByteString -> m ByteString
decompress bytes
  | ByteString.null bytes = pure bytes
  | otherwise =
    case Zstd.decompress bytes of
      Zstd.Skip -> pure bytes
      Zstd.Error err -> throwError (ZstdError err)
      Zstd.Decompress bytes' -> pure bytes'
