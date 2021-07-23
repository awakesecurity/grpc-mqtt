{- 
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}

{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Core (
  connectMQTT,
  heartbeatPeriodSeconds,
) where

import Relude

import Data.Conduit.Network (AppData, appSink, appSource)
import Data.Conduit.Network.TLS (
  TLSClientConfig (tlsClientTLSSettings),
  runTLSClient,
  tlsClientConfig,
 )
import Network.MQTT.Client (
  MQTTClient,
  MQTTConduit,
  MQTTConfig (MQTTConfig, _hostname, _port, _tlsSettings),
  runMQTTConduit,
 )
import Turtle (NominalDiffTime)

-- | Connect to an MQTT broker
connectMQTT :: MonadIO m => MQTTConfig -> m MQTTClient
connectMQTT cfg@MQTTConfig{..} = liftIO $ runMQTTConduit wrapTLS cfg
 where
  wrapTLS :: (MQTTConduit -> IO ()) -> IO ()
  wrapTLS f = runTLSClient tlsCfg (f . toMQTTConduit)

  toMQTTConduit :: AppData -> MQTTConduit
  toMQTTConduit ad = (appSource ad, appSink ad)

  tlsCfg :: TLSClientConfig
  tlsCfg = (tlsClientConfig _port (encodeUtf8 _hostname)){tlsClientTLSSettings = _tlsSettings}

-- | Period for heartbeat messages
heartbeatPeriodSeconds :: NominalDiffTime
heartbeatPeriodSeconds = 10