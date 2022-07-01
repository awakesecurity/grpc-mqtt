-- | This module defines a type-safe wrappers over for the zstandard compression
-- functions.
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Compress
  ( -- * Compression
    compress,

    -- * Zstandard Errors
    ZstdError (GenericError, StreamError),
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

import Text.Show (ShowS)
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
--
-- @since 0.1.0.0
data ZstdError
  = -- | 'GenericError' is a generic zstandard error message emitted from the
    -- zstandard FFI.
    GenericError String
  | -- | 'StreamError' is emitted when attempting to decompress a 'ByteString'
    -- compressed in streaming mode as a single zstandard frame.
    StreamError
  deriving stock (Data, Eq, Ord, Show, Typeable)

-- | @since 0.1.0.0
instance Exception ZstdError where
  displayException err = case err of
    GenericError msg -> showErrorS msg
    StreamError -> showErrorS "input was decompressed in streaming mode."
    where
      showErrorS :: ShowS
      showErrorS = Show.showString "zstd decompression error: "

-- | Convert a 'ZstdError' to a 'RemoteError'.
--
-- @since 0.1.0.0
toRemoteError :: ZstdError -> RemoteError
toRemoteError err =
  let ecode :: Enumerated RError
      ecode = Proto3.Enumerated (Right Proto.RErrorIOGRPCCallInvalidMessage)
   in Proto.RemoteError
        { Proto.remoteErrorErrorType = ecode
        , Proto.remoteErrorMessage = toLText (displayException err)
        , Proto.remoteErrorExtra = Nothing
        }

-- | Decompress a 'ByteString' (compressed via 'compress') as a single
-- zstandard frame.
--
-- * 'StreamError' is emitted if the 'ByteString' was compressed in streaming
--   mode.
--
-- * 'GenericError' is emitted if an error was thrown by the internal zstandard
--   FFI call.
--
-- @since 0.1.0.0
decompress :: MonadError ZstdError m => ByteString -> m ByteString
decompress bytes
  | ByteString.null bytes = pure bytes
  | otherwise =
    case Zstd.decompress bytes of
      Zstd.Skip -> throwError StreamError
      Zstd.Error err -> throwError (GenericError err)
      Zstd.Decompress bytes' -> pure bytes'
