{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Core (
  connectMQTT,
  heartbeatPeriod,
) where

import Relude

import Data.Conduit.Network (AppData, appSink, appSource)
import Data.Conduit.Network.TLS (
  TLSClientConfig (tlsClientTLSSettings),
  runTLSClient,
  tlsClientConfig,
 )
import Network.MQTT.Client
import Network.GRPC.HighLevel.Client (TimeoutSeconds)

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
heartbeatPeriod :: TimeoutSeconds
heartbeatPeriod = 10