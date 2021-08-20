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

logErr :: Logger -> Text -> IO ()
logErr = logVerbosity Error
logWarn :: Logger -> Text -> IO ()
logWarn = logVerbosity Warn
logInfo :: Logger -> Text -> IO ()
logInfo = logVerbosity Info
logDebug :: Logger -> Text -> IO ()
logDebug = logVerbosity Debug

logVerbosity :: Verbosity -> Logger -> Text -> IO ()
logVerbosity v logger msg = when (verbosity logger >= v) $ log logger msg
