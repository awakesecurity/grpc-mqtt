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
noLogging = Logger (\_ -> pure ()) Silent

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
