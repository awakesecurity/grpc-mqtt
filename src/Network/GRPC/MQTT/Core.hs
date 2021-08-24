{-# LANGUAGE DuplicateRecordFields #-}
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
  toFilter,
  defaultMGConfig,
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
import Network.Connection (TLSSettings (TLSSettingsSimple))
import Network.MQTT.Client (
  MQTTClient,
  MQTTConduit,
  MQTTConfig (..),
  MessageCallback (NoCallback),
  runMQTTConduit,
 )
import Network.MQTT.Topic (Filter, Topic (unTopic), mkFilter)
import Network.MQTT.Types (LastWill, Property, ProtocolLevel (Protocol311))
import Relude.Unsafe (fromJust)
import Turtle (NominalDiffTime)

{- |
  Superset of 'MQTTConfig'
-}
data MQTTGRPCConfig = MQTTGRPCConfig
  { useTLS :: Bool
  , mqttMsgSizeLimit :: Int
  
  -- Copy of MQTTConfig
  , _cleanSession :: Bool
  , _lwt :: Maybe LastWill
  , _msgCB :: MessageCallback
  , _protocol :: ProtocolLevel
  , _connProps :: [Property]
  , _hostname :: String
  , _port :: Int
  , _connID :: String
  , _username :: Maybe String
  , _password :: Maybe String
  , _connectTimeout :: Int
  , _tlsSettings :: TLSSettings
  }

defaultMGConfig :: MQTTGRPCConfig
defaultMGConfig =
  MQTTGRPCConfig
    { useTLS = False
    , mqttMsgSizeLimit = 128000
    , _cleanSession = True
    , _lwt = Nothing
    , _msgCB = NoCallback
    , _protocol = Protocol311
    , _connProps = []
    , _hostname = ""
    , _port = 1883
    , _connID = []
    , _username = Nothing
    , _password = Nothing
    , _connectTimeout = 180000000
    , _tlsSettings = TLSSettingsSimple False False False
    }

-- | Project 'MQTTConfig' from 'MQTTGRPCConfig'
getMQTTConfig :: MQTTGRPCConfig -> MQTTConfig
getMQTTConfig MQTTGRPCConfig{..} = MQTTConfig{..}

-- | Connect to an MQTT broker
connectMQTT :: MonadIO m => MQTTGRPCConfig -> m MQTTClient
connectMQTT cfg@MQTTGRPCConfig{..} = liftIO $ do
  let runner = if useTLS then runTLS else runTCP
  runMQTTConduit runner (getMQTTConfig cfg)
 where
  runTLS :: (MQTTConduit -> IO ()) -> IO ()
  runTLS f = runTLSClient tlsCfg (f . toMQTTConduit)

  tlsCfg :: TLSClientConfig
  tlsCfg = (tlsClientConfig _port (encodeUtf8 _hostname)){tlsClientTLSSettings = _tlsSettings}

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
 | This is a bit of a hack, but there is a upstream PR to add this to the net-mqtt
 | library: https://github.com/dustin/mqtt-hs/pull/22
-}
toFilter :: Topic -> Filter
toFilter = fromJust . mkFilter . unTopic
