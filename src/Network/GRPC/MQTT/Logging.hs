-- |
-- Module      :  Network.GRPC.MQTT.Logging
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- Definitions for the 'Logger' type and logging facilities.
--
-- @since 1.0.0
module Network.GRPC.MQTT.Logging
  ( -- * Log Verbosity
    Verbosity (Silent, Error, Warn, Info, Debug),

    -- * Logger
    Logger (Logger, runLog, verbosity),
    noLogging,
    defaultLogger,
    RemoteClientLogger (RemoteClientLogger, formatRequest, formatResponse, logger),
    defaultRemoteClientLogger,
    defaultFormatRequest,
    defaultFormatResponse,

    -- * Logging
    logVerbosity,
    logErr,
    logWarn,
    logInfo,
    logDebug,
  )
where

--------------------------------------------------------------------------------

import Relude

import Data.Text qualified as Text
import Network.GRPC.HighLevel (NormalRequestResult (..), StatusDetails (unStatusDetails))
import Network.GRPC.MQTT.Message.Request
  ( Request (Request, message, metadata),
  )
import Network.GRPC.MQTT.Types (RemoteResult (..))

--------------------------------------------------------------------------------

-- | Enumeration of logger verbosity levels.
--
-- @since 1.0.0
data Verbosity
  = Silent
  | Error
  | Warn
  | Info
  | Debug
  deriving (Bounded, Enum, Eq, Ord, Show)

--------------------------------------------------------------------------------

-- | 'Logger' is IO action writing 'Text' to a log bundled with the minimum
-- log verbosity level used to filter which messages are logged.
--
-- @since 1.0.0
data Logger = Logger
  { runLog :: Text -> IO ()
  , verbosity :: Verbosity
  }

-- | The silent 'Logger'.
--
-- @since 1.0.0
noLogging :: Logger
noLogging =
  Logger
    { runLog = \_ -> pure ()
    , verbosity = Silent
    }

-- | A default 'Logger' that prints to stdout at the `Info` level.
--
-- @since 1.0.0
defaultLogger :: Logger
defaultLogger =
  Logger
    { runLog = print
    , verbosity = Info
    }

-- | 'RemoteClientLogger' wraps a 'Logger' along with formatters.
--
-- @since 1.0.0
data RemoteClientLogger = RemoteClientLogger
  { formatRequest :: Verbosity -> Text -> Request ByteString -> Text
  , formatResponse :: forall s. Verbosity -> RemoteResult s -> Text
  , logger :: Logger
  }

-- | A default 'RemoteClientLogger' that uses 'defaultLogger',
--  'defaultFormatRequest', and 'defaultFormatResponse'.
--
-- @since 1.0.0
defaultRemoteClientLogger :: RemoteClientLogger
defaultRemoteClientLogger =
  RemoteClientLogger
    { formatRequest = defaultFormatRequest
    , formatResponse = defaultFormatResponse
    , logger = defaultLogger
    }

-- | A default formatter for incoming requests.
--  Only displays the message body when the log level is 'Debug'.
--
-- @since 1.0.0
defaultFormatRequest :: Verbosity -> Text -> Request ByteString -> Text
defaultFormatRequest v method Request{metadata, message} =
  Text.intercalate
    ", "
    ( [ "Method: " <> method
      , "Metadata: " <> show metadata
      ]
        ++ ["Body: " <> decodeUtf8 message | v == Debug]
    )

-- | A default formatter for responses.
--  Only displays the response body when the log level is 'Debug'.
--
-- @since 1.0.0
defaultFormatResponse :: Verbosity -> RemoteResult s -> Text
defaultFormatResponse v = \case
  RemoteNormalResult NormalRequestResult{rspBody, rspCode, details, initMD, trailMD} ->
    "NormalResult: "
      <> Text.intercalate
        ", "
        ( [ "Status Code: " <> show rspCode
          , "Status Details: " <> decodeUtf8 (unStatusDetails details)
          , "Inital Metadata: " <> show initMD
          , "Trailing Metadata: " <> show trailMD
          ]
            ++ ["Body: " <> decodeUtf8 rspBody | v == Debug]
        )
  RemoteWriterResult (body, initMD, trailMD, rspCode, details) ->
    "ClientWriterResult: "
      <> Text.intercalate
        ", "
        ( [ "Status Code: " <> show rspCode
          , "Status Details: " <> decodeUtf8 (unStatusDetails details)
          , "Inital Metadata: " <> show initMD
          , "Trailing Metadata: " <> show trailMD
          ]
            ++ ["Body: " <> decodeUtf8 (maybeToMonoid body) | v == Debug]
        )
  RemoteReaderResult (metadata, rspCode, details) ->
    "ClientReaderResult: "
      <> Text.intercalate
        ", "
        [ "Status Code: " <> show rspCode
        , "Status Details: " <> decodeUtf8 (unStatusDetails details)
        , "Metadata: " <> show metadata
        ]
  RemoteBiDiResult (metadata, rspCode, details) ->
    "ClientRWResult: "
      <> Text.intercalate
        ", "
        [ "Status Code: " <> show rspCode
        , "Status Details: " <> decodeUtf8 (unStatusDetails details)
        , "Metadata: " <> show metadata
        ]
  RemoteErrorResult err -> show err

--------------------------------------------------------------------------------

-- | Writes a message with a specified 'Verbosity' to the given 'Logger'.
--
-- @since 1.0.0
logVerbosity :: (MonadIO io) => Verbosity -> Logger -> Text -> io ()
logVerbosity v logger msg =
  when (verbosity logger >= v) do
    liftIO (runLog logger msg)

-- | Writes an error message to the 'Logger'.
--
-- @since 1.0.0
logErr :: (MonadIO io) => Logger -> Text -> io ()
logErr = logVerbosity Error

-- | Writes a warning to the 'Logger'.
--
-- @since 1.0.0
logWarn :: (MonadIO io) => Logger -> Text -> io ()
logWarn = logVerbosity Warn

-- | Writes a message to the 'Logger'.
--
-- @since 1.0.0
logInfo :: (MonadIO io) => Logger -> Text -> io ()
logInfo = logVerbosity Info

-- | Writes debug information to the 'Logger'.
--
-- @since 1.0.0
logDebug :: (MonadIO io) => Logger -> Text -> io ()
logDebug = logVerbosity Debug
