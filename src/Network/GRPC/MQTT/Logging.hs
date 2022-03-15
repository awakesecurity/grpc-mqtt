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

logErr :: (MonadIO io) => Logger -> Text -> io ()
logErr = logVerbosity Error
logWarn :: (MonadIO io) => Logger -> Text -> io ()
logWarn = logVerbosity Warn
logInfo :: (MonadIO io) => Logger -> Text -> io ()
logInfo = logVerbosity Info
logDebug :: (MonadIO io) => Logger -> Text -> io ()
logDebug = logVerbosity Debug

logVerbosity :: (MonadIO io) => Verbosity -> Logger -> Text -> io ()
logVerbosity v logger msg = do
  print $ verbosity logger
  print v
  print msg
  when (verbosity logger >= v) $ liftIO (log logger msg)
