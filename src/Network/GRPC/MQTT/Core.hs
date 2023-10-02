{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      :  Network.GRPC.MQTT.Core
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- Module defintions core components required by the library.
--
-- @since 1.0.0
module Network.GRPC.MQTT.Core
  ( MQTTGRPCConfig (..),
    connectMQTT,
    heartbeatPeriodSeconds,
    defaultMGConfig,
    subscribeOrThrow,
    withSubscription,
    Publisher,
    mkSequencedPublish,
    readIndexFromProperties,
  )
where

--------------------------------------------------------------------------------

import Control.Concurrent.OrderedTQueue (SequenceId (SequenceId, Unordered))

import Control.Exception (bracket_, throw)

import Data.Conduit.Network (AppData, appSink, appSource)
import Data.Conduit.Network.TLS
  ( TLSClientConfig
      ( tlsClientSockSettings,
        tlsClientTLSSettings,
        tlsClientUseTLS
      ),
    runTLSClient,
    tlsClientConfig,
  )

import Data.Time.Clock (NominalDiffTime)

import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.List qualified as L

import Network.Connection (ProxySettings, TLSSettings (TLSSettingsSimple))

import Network.MQTT.Client
  ( MQTTClient,
    MQTTConduit,
    MQTTConfig
      ( MQTTConfig,
        _cleanSession,
        _connID,
        _connProps,
        _connectTimeout,
        _hostname,
        _lwt,
        _msgCB,
        _password,
        _port,
        _protocol,
        _tlsSettings,
        _username
      ),
    MQTTException (MQTTException),
    MessageCallback (NoCallback),
    Property (PropUserProperty),
    QoS (QoS1),
    SubOptions (_subQoS),
    Topic,
    publishq,
    runMQTTConduit,
    subOptions,
    subscribe,
    unsubscribe,
  )
import Network.MQTT.Topic (Filter (unFilter))
import Network.MQTT.Types (LastWill, ProtocolLevel (Protocol50), SubErr)

import Relude

--------------------------------------------------------------------------------

-- | Superset of 'MQTTConfig'
--
-- @since 1.0.0
data MQTTGRPCConfig = MQTTGRPCConfig
  { -- | Whether or not to use TLS for the connection
    useTLS :: Bool
  , -- | Maximum size for an MQTT message in bytes. This value must be greater
    -- than or equal to 16 bytes and less than 256mB, see:
    -- 'Network.GRPC.MQTT.Message.Packet.makePacketSender'.
    mqttMsgSizeLimit :: Word32
  , -- | Proxy to use to connect to the MQTT broker
    brokerProxy :: Maybe ProxySettings
  , -- | Limit the rate of publishing data to the MQTT broker in bytes per second.
    -- 4GiB/s is the maximum allowed rate. If a rate larger than 4GiB/s is supplied,
    -- publishing will still be limited to 4GiB/s
    -- If this option is not supplied, no rate limit is applied.
    mqttPublishRateLimit :: Maybe Natural
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

-- | The default 'MQTTGRPCConfig'.
--
-- @since 1.0.0
defaultMGConfig :: MQTTGRPCConfig
defaultMGConfig =
  MQTTGRPCConfig
    { useTLS = False
    , mqttMsgSizeLimit = 128000
    , brokerProxy = Nothing
    , mqttPublishRateLimit = Nothing
    , _cleanSession = True
    , _lwt = Nothing
    , _msgCB = NoCallback
    , _protocol = Protocol50
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
--
-- @since 1.0.0
getMQTTConfig :: MQTTGRPCConfig -> MQTTConfig
getMQTTConfig MQTTGRPCConfig{..} = MQTTConfig{..}

-- | Connect to an MQTT broker
--
-- @since 1.0.0
connectMQTT :: (MonadIO io) => MQTTGRPCConfig -> io MQTTClient
connectMQTT cfg@MQTTGRPCConfig{..} = liftIO $ runMQTTConduit runClient (getMQTTConfig cfg)
  where
    runClient :: (MQTTConduit -> IO a) -> IO a
    runClient app = runTLSClient tlsCfg (app . toMQTTConduit)

    tlsCfg :: TLSClientConfig
    tlsCfg =
      (tlsClientConfig _port (ByteString.Char8.pack _hostname))
        { tlsClientTLSSettings = _tlsSettings
        , tlsClientUseTLS = useTLS
        , tlsClientSockSettings = brokerProxy
        }

    toMQTTConduit :: AppData -> MQTTConduit
    toMQTTConduit ad = (appSource ad, appSink ad)

-- | Period for heartbeat messages
--
-- @since 1.0.0
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
    errMsg (topic, subErr) =
      "Failed to subscribe to the topic: "
        <> toString (unFilter topic)
        <> "Reason: "
        <> show subErr

withSubscription :: MQTTClient -> [Filter] -> IO a -> IO a
withSubscription client topics =
  bracket_
    (subscribeOrThrow client topics)
    (unsubscribe client topics [])

-- | A type synonym representing a simplified function for publishing MQTT messages
type Publisher = MQTTClient -> Topic -> LByteString -> IO ()

-- | Returns a MQTT `Publisher` which will annotate each MQTT message with a 
-- sequence number as a user property "i". The sequence number will be incremented
-- each time a message is published.
mkSequencedPublish :: MonadIO m => m Publisher
mkSequencedPublish = do
  indexVar <- newTVarIO (0 :: Natural)

  let sequencedPublish client topic message = do
        index <- atomically do
          i <- readTVar indexVar
          modifyTVar' indexVar (+ 1)
          pure i

        publishq client topic message False QoS1 [PropUserProperty "i" (show index)]

  pure sequencedPublish

-- | Takes the first user property "i" as a `SequnceId`. Or returns `Unordered`
-- if no "i" property is present or the value fails to parse as a `Natural`.
readIndexFromProperties :: [Property] -> SequenceId
readIndexFromProperties props = maybe Unordered SequenceId do
  v <- listToMaybe do
    PropUserProperty "i" v <- props
    pure (decodeUtf8 v)
  readMaybe v
