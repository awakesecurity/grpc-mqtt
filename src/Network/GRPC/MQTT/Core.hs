{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Core (
  MQTTConnectionConfig (..),
  connectMQTT,
  heartbeatPeriodSeconds,
  setCallback,
  setConnectionId,
  Logger (..),
  Verbosity (..),
  logErr,
  logWarn,
  logInfo,
  logDebug,
  noLogging
) where

import Relude

import Data.Conduit.Network (AppData, ClientSettings, appSink, appSource, clientSettings, runTCPClient)
import Data.Conduit.Network.TLS (
  TLSClientConfig (tlsClientTLSSettings),
  runTLSClient,
  tlsClientConfig,
 )
import Network.MQTT.Client (
  MQTTClient,
  MQTTConduit,
  MQTTConfig (MQTTConfig, _connID, _hostname, _msgCB, _port, _tlsSettings),
  MessageCallback,
  runMQTTConduit,
 )
import Turtle (NominalDiffTime)

data Logger = Logger
  { log :: Text -> IO ()
  , verbosity :: Verbosity
  }

noLogging :: Logger
noLogging = Logger (\_ -> pure ()) Silent

data Verbosity
  = Silent
  | Error
  | Warn
  | Info
  | Debug
  deriving (Show, Eq, Enum, Ord)

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

{- |
  Wrapper around 'MQTTConfig' indicating whether or not to use TLS for the
  connection to the MQTT broker
-}
data MQTTConnectionConfig
  = Secured MQTTConfig
  | Unsecured MQTTConfig

setCallback :: MessageCallback -> MQTTConnectionConfig -> MQTTConnectionConfig
setCallback cb (Secured cfg) = Secured cfg{_msgCB = cb}
setCallback cb (Unsecured cfg) = Unsecured cfg{_msgCB = cb}

setConnectionId :: String -> MQTTConnectionConfig -> MQTTConnectionConfig
setConnectionId cid (Secured cfg) = Secured cfg{_connID = cid}
setConnectionId cid (Unsecured cfg) = Unsecured cfg{_connID = cid}

-- | Connect to an MQTT broker
connectMQTT :: MonadIO m => MQTTConnectionConfig -> m MQTTClient
connectMQTT = \case
  Secured cfg@MQTTConfig{..} -> liftIO $ runMQTTConduit runTLS cfg
   where
    runTLS :: (MQTTConduit -> IO ()) -> IO ()
    runTLS f = runTLSClient tlsCfg (f . toMQTTConduit)

    tlsCfg :: TLSClientConfig
    tlsCfg = (tlsClientConfig _port (encodeUtf8 _hostname)){tlsClientTLSSettings = _tlsSettings}
  Unsecured cfg@MQTTConfig{..} -> liftIO $ runMQTTConduit runTCP cfg
   where
    runTCP :: (MQTTConduit -> IO ()) -> IO ()
    runTCP f = runTCPClient tcpCfg (f . toMQTTConduit)

    tcpCfg :: ClientSettings
    tcpCfg = clientSettings _port (encodeUtf8 _hostname)

toMQTTConduit :: AppData -> MQTTConduit
toMQTTConduit ad = (appSource ad, appSink ad)

-- | Period for heartbeat messages
heartbeatPeriodSeconds :: NominalDiffTime
heartbeatPeriodSeconds = 10