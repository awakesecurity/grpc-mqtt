{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Core
  ( MQTTGRPCConfig (..),
    connectMQTT,
    heartbeatPeriodSeconds,
    defaultMGConfig,
    subscribeOrThrow,
  )
where

import Relude

import Control.Exception (throw)
import Data.Conduit.Network
  ( AppData,
    appSink,
    appSource,
  )
import Data.Conduit.Network.TLS
  ( TLSClientConfig (..),
    runTLSClient,
    tlsClientConfig,
  )
import qualified Data.List as L
import Network.Connection (ProxySettings, TLSSettings (TLSSettingsSimple))
import Network.MQTT.Client
  ( MQTTClient,
    MQTTConduit,
    MQTTConfig (..),
    MQTTException (MQTTException),
    MessageCallback (NoCallback),
    QoS (QoS1),
    SubOptions (_subQoS),
    runMQTTConduit,
    subOptions,
    subscribe,
  )
import Network.MQTT.Topic (Filter (unFilter))
import Network.MQTT.Types (LastWill, Property, ProtocolLevel (Protocol311), SubErr)
import Turtle (NominalDiffTime)

{- |
  Superset of 'MQTTConfig'
-}
data MQTTGRPCConfig = MQTTGRPCConfig
  { -- | Whether or not to use TLS for the connection
    useTLS :: Bool
  , -- | Maximum size for an MQTT message in bytes
    mqttMsgSizeLimit :: Int
  , -- | Proxy to use to connect to the MQTT broker
    brokerProxy :: Maybe ProxySettings
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
    , brokerProxy = Nothing
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
connectMQTT :: (MonadIO io) => MQTTGRPCConfig -> io MQTTClient
connectMQTT cfg@MQTTGRPCConfig{..} = liftIO $ runMQTTConduit runClient (getMQTTConfig cfg)
  where
    runClient :: (MQTTConduit -> IO a) -> IO a
    runClient app = runTLSClient tlsCfg (app . toMQTTConduit)

    tlsCfg :: TLSClientConfig
    tlsCfg =
      (tlsClientConfig _port (encodeUtf8 _hostname))
        { tlsClientTLSSettings = _tlsSettings
        , tlsClientUseTLS = useTLS
        , tlsClientSockSettings = brokerProxy
        }

    toMQTTConduit :: AppData -> MQTTConduit
    toMQTTConduit ad = (appSource ad, appSink ad)

-- | Period for heartbeat messages
heartbeatPeriodSeconds :: NominalDiffTime
heartbeatPeriodSeconds = 10

subscribeOrThrow :: MQTTClient -> [Filter] -> IO ()
subscribeOrThrow client topics = do
  let subTopics = zip topics (repeat subOptions{_subQoS = QoS1})
  (subResults, _) <- subscribe client subTopics []
  let taggedResults = zipWith (\t -> first (t,)) topics subResults
  let subFailures = lefts taggedResults
  unless (null subFailures) $ do
    let err = L.unlines $ fmap errMsg subFailures
    throw $ MQTTException err
  where
    errMsg :: (Filter, SubErr) -> String
    errMsg (topic, subErr) = "Failed to subscribe to the topic: " <> toString (unFilter topic) <> "Reason: " <> show subErr
