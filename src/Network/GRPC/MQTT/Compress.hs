-- | TODO
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Compress
  ( -- * Compression
    compress,

    -- * Decompression
    ZstdError (GenericError, StreamError),
    toRemoteError,
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

-- | TODO
--
-- @since 0.1.0.0
compress :: CLevel -> ByteString -> ByteString
compress level bytes
  | ByteString.null bytes = bytes
  | otherwise = Zstd.compress (CLevel.fromCLevel level) bytes

-- Decompression ---------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
data ZstdError
  = GenericError String
  | StreamError
  deriving stock (Data, Eq, Ord, Typeable)

-- | @since 0.1.0.0
instance Show ZstdError where
  show err = case err of
    GenericError msg -> showErrorS msg
    StreamError -> showErrorS "input was decompressed in streaming mode."
    where
      showErrorS :: ShowS
      showErrorS = Show.showString "zstd decompression error: "

-- | @since 0.1.0.0
instance Exception ZstdError where
  displayException err = show err

-- | TODO
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

-- | TODO
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

-- typedef enum {
--   ZSTD_error_no_error = 0,
--   ZSTD_error_GENERIC  = 1,
--   ZSTD_error_prefix_unknown                = 10,
--   ZSTD_error_version_unsupported           = 12,
--   ZSTD_error_frameParameter_unsupported    = 14,
--   ZSTD_error_frameParameter_windowTooLarge = 16,
--   ZSTD_error_corruption_detected = 20,
--   ZSTD_error_checksum_wrong      = 22,
--   ZSTD_error_dictionary_corrupted      = 30,
--   ZSTD_error_dictionary_wrong          = 32,
--   ZSTD_error_dictionaryCreation_failed = 34,
--   ZSTD_error_parameter_unsupported   = 40,
--   ZSTD_error_parameter_outOfBound    = 42,
--   ZSTD_error_tableLog_tooLarge       = 44,
--   ZSTD_error_maxSymbolValue_tooLarge = 46,
--   ZSTD_error_maxSymbolValue_tooSmall = 48,
--   ZSTD_error_stabilityCondition_notRespected = 50,
--   ZSTD_error_stage_wrong       = 60,
--   ZSTD_error_init_missing      = 62,
--   ZSTD_error_memory_allocation = 64,
--   ZSTD_error_workSpace_tooSmall= 66,
--   ZSTD_error_dstSize_tooSmall = 70,
--   ZSTD_error_srcSize_wrong    = 72,
--   ZSTD_error_dstBuffer_null   = 74,
--   /* following error codes are __NOT STABLE__, they can be removed or changed in future versions */
--   ZSTD_error_frameIndex_tooLarge = 100,
--   ZSTD_error_seekableIO          = 102,
--   ZSTD_error_dstBuffer_wrong     = 104,
--   ZSTD_error_srcBuffer_wrong     = 105,
--   ZSTD_error_maxCode = 120  /* never EVER use this value directly, it can change in future versions! Use ZSTD_isError() instead */
-- } ZSTD_ErrorCode;
