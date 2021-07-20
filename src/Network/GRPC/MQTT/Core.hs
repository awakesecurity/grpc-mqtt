{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Core (
  connectMQTT,
  heartbeatPeriodSeconds,
) where

import Relude

import Data.Conduit.Network (AppData, appSink, appSource, runTCPClient, clientSettings, ClientSettings)
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
connectMQTT :: MonadIO m => MQTTConfig -> Bool -> m MQTTClient
connectMQTT cfg@MQTTConfig{..} useTLS = liftIO $ runMQTTConduit runClient cfg
  where
    runClient = if useTLS then runTLS else runTCP
    
    runTCP :: (MQTTConduit -> IO ()) -> IO ()
    runTCP f = runTCPClient tcpCfg (f . toMQTTConduit)
    
    runTLS :: (MQTTConduit -> IO ()) -> IO ()
    runTLS f = runTLSClient tlsCfg (f . toMQTTConduit)

    toMQTTConduit :: AppData -> MQTTConduit
    toMQTTConduit ad = (appSource ad, appSink ad)

    tlsCfg :: TLSClientConfig
    tlsCfg = (tlsClientConfig _port (encodeUtf8 _hostname)){tlsClientTLSSettings = _tlsSettings}

    tcpCfg :: ClientSettings
    tcpCfg = clientSettings _port (encodeUtf8 _hostname)

-- | Period for heartbeat messages
heartbeatPeriodSeconds :: NominalDiffTime
heartbeatPeriodSeconds = 10