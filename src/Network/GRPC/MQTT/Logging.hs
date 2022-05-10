{-# LANGUAGE ImplicitPrelude #-}
-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.


-- | TODO
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

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)

import Data.Text (Text)

--------------------------------------------------------------------------------

-- | TODO
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

-- | TODO
--
-- @since 1.0.0
data Logger = Logger
  { runLog :: Text -> IO ()
  , verbosity :: Verbosity
  }

-- | TODO
--
-- @since 1.0.0
noLogging :: Logger
noLogging = Logger (\_ -> pure ()) Silent

--------------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
logVerbosity :: (MonadIO io) => Verbosity -> Logger -> Text -> io ()
logVerbosity v logger msg =
  when (verbosity logger >= v) do
    liftIO (runLog logger msg)

-- | TODO
--
-- @since 1.0.0
logErr :: (MonadIO io) => Logger -> Text -> io ()
logErr = logVerbosity Error

-- | TODO
--
-- @since 1.0.0
logWarn :: (MonadIO io) => Logger -> Text -> io ()
logWarn = logVerbosity Warn

-- | TODO
--
-- @since 1.0.0
logInfo :: (MonadIO io) => Logger -> Text -> io ()
logInfo = logVerbosity Info

-- | TODO
--
-- @since 1.0.0
logDebug :: (MonadIO io) => Logger -> Text -> io ()
logDebug = logVerbosity Debug

