{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

module Test.Suite.Config
  ( -- * Test Suite Configuration
    -- $test-suite-configuration
    TestConfig
      ( TestConfig,
        testConfigBrokerPort,
        testConfigServerPort,
        testConfigServerHost,
        testConfigBaseTopic
      ),
    withTestConfig,

    -- * Query Test Config
    askServiceOptions,
    askConfigClientGRPC,
    askConfigMQTT,
    askClientConfigMQTT,
    askRemoteConfigMQTT,

    -- * Test Suite Options
    -- $test-suite-options
    TestOption (TestOption, getTestOption),
    askTestOption,
  )
where

--------------------------------------------------------------------------------

import Test.Tasty (TestTree)
import Test.Tasty qualified as Tasty
import Test.Tasty.Options
  ( IsOption,
    defaultValue,
    optionHelp,
    optionName,
    parseValue,
    safeRead,
  )

--------------------------------------------------------------------------------

import Control.Monad.Cont (cont, runCont)
import Control.Monad.Reader

import Data.Default (def)

import Data.ByteString.Char8 qualified as ByteString.Char8

import Data.X509.CertificateStore (readCertificateStore)

import GHC.TypeLits (Symbol)

import Network.Connection (TLSSettings (TLSSettings))

import Network.GRPC.HighLevel.Client (ClientConfig, Host, Port)
import Network.GRPC.HighLevel.Client qualified as GRPC.Client
import Network.GRPC.HighLevel.Generated (Host (..), Port (..), ServiceOptions)
import Network.GRPC.HighLevel.Generated qualified as GRPC.Generated
import Network.GRPC.LowLevel.Call (Endpoint (..))
import Network.GRPC.Unsafe.ChannelArgs (Arg (..))

import Network.MQTT.Topic (Topic)

import Network.TLS (defaultParamsClient)
import Network.TLS qualified as TLS
import Network.TLS.Extra.Cipher (ciphersuite_default)

import GHC.IO (throwIO)
import GHC.IO.Exception (userError)
import Relude

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Core (MQTTGRPCConfig)
import Network.GRPC.MQTT.Core qualified as GRPC.MQTT

--------------------------------------------------------------------------------

data TestConfig = TestConfig
  { testConfigBrokerPort :: Port
  , testConfigBrokerHost :: Host
  , testConfigServerPort :: Port
  , testConfigServerHost :: Host
  , testConfigBaseTopic :: Topic
  , testConfigClientId :: String
  , testConfigRemoteId :: String
  , testConfigCertificatePath :: Maybe FilePath
  , testConfigPrivateKeyPath :: Maybe FilePath
  , testConfigCertStorePath :: Maybe FilePath
  }
  deriving (Eq, Show)

withTestConfig :: (TestConfig -> TestTree) -> TestTree
withTestConfig = runCont do
  brokerPort <- cont (askTestOption @"broker-port")
  brokerHost <- cont (askTestOption @"broker-host")
  serverPort <- cont (askTestOption @"server-port")
  serverHost <- cont (askTestOption @"server-host")
  baseTopic <- cont (askTestOption @"base-topic")
  clientId <- cont (askTestOption @"client-id")
  remoteId <- cont (askTestOption @"remote-id")
  certificatePath <- cont (askTestOption @"certificate-path")
  privateKeyPath <- cont (askTestOption @"private-key-path")
  certStorePath <- cont (askTestOption @"certificate-store-path")
  pure $
    TestConfig
      { testConfigBrokerPort = brokerPort
      , testConfigBrokerHost = brokerHost
      , testConfigServerPort = serverPort
      , testConfigServerHost = serverHost
      , testConfigBaseTopic = baseTopic
      , testConfigClientId = clientId
      , testConfigRemoteId = remoteId
      , testConfigCertificatePath = certificatePath
      , testConfigPrivateKeyPath = privateKeyPath
      , testConfigCertStorePath = certStorePath
      }

askServiceOptions :: MonadReader TestConfig m => m ServiceOptions
askServiceOptions = do
  port <- asks testConfigServerPort
  pure
    GRPC.Generated.defaultServiceOptions
      { GRPC.Generated.serverPort = port
      , GRPC.Generated.serverMaxReceiveMessageLength = Just 268435456
      , GRPC.Generated.serverMaxMetadataSize = Just 100_000_000_000_000
      }

askConfigClientGRPC :: MonadReader TestConfig m => m ClientConfig
askConfigClientGRPC = do
  Host host <- asks testConfigServerHost
  Port port <- asks testConfigServerPort
  let config :: ClientConfig
      config =
        GRPC.Client.ClientConfig
          { GRPC.Client.clientServerEndpoint = Endpoint $ host <> ":" <> show port
          , GRPC.Client.clientArgs =
              [MaxReceiveMessageLength 268435456]
          , GRPC.Client.clientSSLConfig = Nothing
          , GRPC.Client.clientAuthority = Nothing
          }
   in pure config

askConfigMQTT :: (MonadReader TestConfig m, MonadIO m) => m MQTTGRPCConfig
askConfigMQTT = do
  GRPC.Client.Host host <- asks testConfigBrokerHost
  GRPC.Client.Port port <- asks testConfigBrokerPort

  mcertFilepath <- asks testConfigCertificatePath
  mprivKeyFilepath <- asks testConfigPrivateKeyPath
  mcertStoreFilepath <- asks testConfigCertStorePath

  (tlsSettings, useTLS) <- case (mcertFilepath, mprivKeyFilepath, mcertStoreFilepath) of
    (Just certFilepath, Just privKeyFilepath, Just certStoreFilepath) -> do
      cred <-
        liftIO $
          TLS.credentialLoadX509 certFilepath privKeyFilepath >>= \case
            Right c -> pure c
            Left err -> throwIO $ userError ("Failed to load TLS credentials: " <> show err)
      certStore <-
        liftIO $
          readCertificateStore certStoreFilepath >>= \case
            Just cs -> pure cs
            Nothing -> throwIO $ userError "Failed to read cert store"

      let settings =
            TLSSettings
              (defaultParamsClient (decodeUtf8 host) "")
                { TLS.clientSupported = def{TLS.supportedCiphers = ciphersuite_default}
                , TLS.clientShared =
                    def
                      { TLS.sharedCredentials = TLS.Credentials [cred]
                      , TLS.sharedCAStore = certStore
                      }
                , TLS.clientHooks = def{TLS.onCertificateRequest = \_ -> return (Just cred)}
                }
      pure (settings, True)
    _ -> pure (def, False)

  pure
    GRPC.MQTT.defaultMGConfig
      { GRPC.MQTT._hostname = ByteString.Char8.unpack host
      , GRPC.MQTT._port = port
      , GRPC.MQTT._tlsSettings = tlsSettings
      , GRPC.MQTT.useTLS = useTLS
      }

askClientConfigMQTT :: (MonadReader TestConfig m, MonadIO m) => m MQTTGRPCConfig
askClientConfigMQTT = do
  clientid <- asks testConfigClientId
  config <- askConfigMQTT
  pure
    config
      { GRPC.MQTT._connID = clientid
      }

askRemoteConfigMQTT :: (MonadReader TestConfig m, MonadIO m) => m MQTTGRPCConfig
askRemoteConfigMQTT = do
  remoteid <- asks testConfigRemoteId
  config <- askConfigMQTT
  pure
    config
      { GRPC.MQTT._connID = remoteid
      }

--------------------------------------------------------------------------------

data TestOption (opt :: Symbol) (a :: Type) :: Type where
  TestOption :: forall opt a. {getTestOption :: a} -> TestOption opt a
  deriving (Typeable, Show)

-- | Identitical to 'Tasty.askOption' except for handling the unwrapping of
-- 'TestOption', intended to be used via type application:
--
-- >>> askTestOption @"broker-port" @Port
askTestOption :: forall opt a. IsOption (TestOption opt a) => (a -> TestTree) -> TestTree
askTestOption k =
  let continue :: TestOption opt a -> TestTree
      continue (TestOption x) = k x
   in Tasty.askOption continue

--- Tasty Option Instances ------------------------------------------------------

parsePort :: String -> Maybe Port
parsePort input = do
  port <- safeRead input
  if port <= 65_535
    then Just (GRPC.Client.Port port)
    else Nothing

instance IsOption (TestOption "broker-port" Port) where
  optionName = "broker-port"
  optionHelp = "The port used by the MQTT broker."

  -- Default port used by mosquitto
  defaultValue = TestOption @"broker-port" 1883

  parseValue = fmap (TestOption @"broker-port") . parsePort

instance IsOption (TestOption "broker-host" Host) where
  optionName = "broker-host"
  optionHelp = "The hostname used by the MQTT broker."

  defaultValue = TestOption @"broker-host" "localhost"

  parseValue = Just . TestOption @"broker-host" . GRPC.Client.Host . ByteString.Char8.pack

instance IsOption (TestOption "server-port" Port) where
  optionName = "server-port"
  optionHelp = "The port used by the test gRPC services."

  defaultValue = TestOption @"server-port" 50_051

  parseValue = fmap (TestOption @"server-port") . parsePort

instance IsOption (TestOption "server-host" Host) where
  optionName = "server-host"
  optionHelp = "The hostname used by the test gRPC services."

  defaultValue = TestOption @"server-host" "localhost"

  parseValue = Just . TestOption @"server-host" . GRPC.Client.Host . ByteString.Char8.pack

instance IsOption (TestOption "base-topic" Topic) where
  optionName = "base-topic"
  optionHelp = "The base topic used by the MQTT broker."

  defaultValue = TestOption @"base-topic" "testMachine/testclient"

  parseValue = Just . TestOption @"base-topic" . fromString

instance IsOption (TestOption "client-id" String) where
  optionName = "client-id"
  optionHelp = "The connection ID used by the MQTT client."

  defaultValue = TestOption @"client-id" "Test.Client"

  parseValue = Just . TestOption @"client-id" . fromString

instance IsOption (TestOption "remote-id" String) where
  optionName = "remote-id"
  optionHelp = "The connection ID used by the remote client."

  defaultValue = TestOption @"remote-id" "Test.Adaptor"

  parseValue = Just . TestOption @"remote-id" . fromString

instance IsOption (TestOption "certificate-path" (Maybe FilePath)) where
  optionName = "certificate-path"
  optionHelp = "Path to client TLS certificate for MQTTS."

  defaultValue = TestOption @"certificate-path" Nothing

  parseValue = Just . TestOption @"certificate-path" . Just . fromString

instance IsOption (TestOption "private-key-path" (Maybe FilePath)) where
  optionName = "private-key-path"
  optionHelp = "Path to client TLS private key file for MQTTS."

  defaultValue = TestOption @"private-key-path" Nothing

  parseValue = Just . TestOption @"private-key-path" . Just . fromString

instance IsOption (TestOption "certificate-store-path" (Maybe FilePath)) where
  optionName = "certificate-store-path"
  optionHelp = "Path to SSL certificate store for MQTTS."

  defaultValue = TestOption @"certificate-store-path" Nothing

  parseValue = Just . TestOption @"certificate-store-path" . Just . fromString
