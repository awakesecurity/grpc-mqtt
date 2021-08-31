{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
module Network.GRPC.MQTT.Logging where

import Relude

data Logger = Logger
  { log :: Text -> IO ()
  , verbosity :: Verbosity
  }

data Verbosity
  = Silent
  | Error
  | Warn
  | Info
  | Debug
  deriving (Show, Eq, Enum, Ord)

noLogging :: Logger
noLogging = Logger (\_ -> pure ()) Silent

logErr :: (MonadIO m) => Logger -> Text -> m ()
logErr = logVerbosity Error
logWarn :: (MonadIO m) => Logger -> Text -> m ()
logWarn = logVerbosity Warn
logInfo :: (MonadIO m) => Logger -> Text -> m ()
logInfo = logVerbosity Info
logDebug :: (MonadIO m) => Logger -> Text -> m ()
logDebug = logVerbosity Debug

logVerbosity :: (MonadIO m) => Verbosity -> Logger -> Text -> m ()
logVerbosity v logger msg = when (verbosity logger >= v) $ liftIO (log logger msg)
