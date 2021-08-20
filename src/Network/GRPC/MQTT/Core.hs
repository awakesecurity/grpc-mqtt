{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Core (
  MQTTGRPCConfig (..),
  connectMQTT,
  heartbeatPeriodSeconds,
  setCallback,
  setConnectionId,
  toFilter,
) where

import Relude

import Data.Conduit.Network (
  AppData,
  ClientSettings,
  appSink,
  appSource,
  clientSettings,
  runTCPClient,
 )
import Data.Conduit.Network.TLS (
  TLSClientConfig (tlsClientTLSSettings),
  runTLSClient,
  tlsClientConfig,
 )
import Network.MQTT.Client (
  MQTTClient,
  MQTTConduit,
  MQTTConfig (..),
  MessageCallback,
  runMQTTConduit,
 )
import Network.MQTT.Topic (Filter, Topic (unTopic), mkFilter)
import Relude.Unsafe (fromJust)
import Turtle (NominalDiffTime)

{- |
  Wrapper around 'MQTTConfig' indicating whether or not to use TLS for the
  connection to the MQTT broker
-}
data MQTTGRPCConfig
  = Secured MQTTConfig
  | Unsecured MQTTConfig

-- | Utility for setting the callback within the 'MQTTConfig'
setCallback :: MessageCallback -> MQTTGRPCConfig -> MQTTGRPCConfig
setCallback cb (Secured cfg) = Secured cfg{_msgCB = cb}
setCallback cb (Unsecured cfg) = Unsecured cfg{_msgCB = cb}

-- | Utility for setting the connection ID within the 'MQTTConfig'
setConnectionId :: String -> MQTTGRPCConfig -> MQTTGRPCConfig
setConnectionId cid (Secured cfg) = Secured cfg{_connID = cid}
setConnectionId cid (Unsecured cfg) = Unsecured cfg{_connID = cid}

-- | Connect to an MQTT broker
connectMQTT :: MonadIO m => MQTTGRPCConfig -> m MQTTClient
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

{- | Topics are strictly a subset of 'Filter's so this conversion is always safe
 | <net-mqtt PR here>
-}
toFilter :: Topic -> Filter
toFilter = fromJust . mkFilter . unTopic
