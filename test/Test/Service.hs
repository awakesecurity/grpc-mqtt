{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ImplicitPrelude #-}

-- |
module Test.Service
  ( tests,
    makeNormalCall,
  )
where

--------------------------------------------------------------------------------

import Hedgehog

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TMVar (newEmptyTMVarIO, putTMVar, readTMVar)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)

import Control.Monad.IO.Class (liftIO)

import Data.Default (Default (def))
import Data.Foldable (traverse_)

import Data.String (fromString)

import Network.Connection (TLSSettings (TLSSettings))

import Network.GRPC.HighLevel.Client
  ( ClientConfig
      ( ClientConfig,
        clientArgs,
        clientAuthority,
        clientSSLConfig,
        clientServerHost,
        clientServerPort
      ),
    ClientResult
      ( ClientBiDiResponse,
        ClientErrorResponse,
        ClientNormalResponse,
        ClientReaderResponse,
        ClientWriterResponse
      ),
    MetadataMap,
    Port,
    StreamRecv,
    StreamSend,
    WritesDone,
  )
import Network.GRPC.HighLevel.Generated
  ( GRPCMethodType (BiDiStreaming, ClientStreaming, Normal, ServerStreaming),
    ServiceOptions (serverPort),
    StatusCode (StatusOk),
    defaultServiceOptions,
    withGRPCClient,
  )

import Network.MQTT.Topic (Topic)

import Network.TLS
  ( ClientHooks (onCertificateRequest),
    ClientParams (clientHooks, clientShared, clientSupported),
    Credential,
    Credentials (Credentials),
    HostName,
    Shared (sharedCAStore, sharedCredentials),
    Supported (supportedCiphers),
    credentialLoadX509,
    defaultParamsClient,
  )
import Network.TLS.Extra.Cipher (ciphersuite_default)

import Turtle (sleep)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT
  ( ProtocolLevel (Protocol311),
  )
import Network.GRPC.MQTT.Client
  ( MQTTGRPCClient (mqttClient),
    withMQTTGRPCClient,
  )
import Network.GRPC.MQTT.Core
import Network.GRPC.MQTT.Logging (Logger (Logger), Verbosity (Debug, Silent))
import Network.GRPC.MQTT.RemoteClient
  ( runRemoteClient,
  )
import Network.GRPC.MQTT.Types
  ( MQTTRequest (MQTTBiDiRequest, MQTTNormalRequest, MQTTReaderRequest, MQTTWriterRequest),
    MQTTResult (GRPCResult, MQTTError),
  )

import Test.Proto.Clients (testServiceMqttClient)
import Test.Proto.RemoteClients (testServiceRemoteClientMethodMap)
import Test.Proto.Service (newTestService)

import Proto.Message (BiRqtRpy, OneInt, SSRpy, SSRqt, TwoInts)
import Proto.Message qualified as Message
import Proto.Service
  ( TestService
      ( TestService,
        testServiceBiDi,
        testServiceClientStream,
        testServiceNormal,
        testServiceServerStream
      ),
  )

--------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Test.Service"
    [ testProperty "Normal RPC Call" testNormalCall
    , testProperty "Client Stream RPC Call" testClientStreamCall
    , testProperty "Server Stream RPC Call" testServerStreamCall
    , testProperty "BiDi Stream RPC Call" testBiDiCall
    ]

runTestService :: IO ()
runTestService =
  newTestService
    defaultServiceOptions
      { serverPort = 50051
      }

testClientId :: String
testClientId = "testClient"

testBaseTopic :: Topic
testBaseTopic = "testMachine" <> fromString testClientId

clientConfigGRPC :: Port -> ClientConfig
clientConfigGRPC port =
  ClientConfig
    { clientServerHost = "localhost"
    , clientServerPort = port
    , clientArgs = []
    , clientSSLConfig = Nothing
    , clientAuthority = Nothing
    }

configGrpcMqtt :: MQTTGRPCConfig
configGrpcMqtt =
  defaultMGConfig
    { useTLS = False
    , mqttMsgSizeLimit = 128000
    , _protocol = Protocol311
    , _hostname = "localhost"
    , _port = 1883
    , _tlsSettings =
        TLSSettings
          (defaultParamsClient "localhost" "")
            { clientSupported = def{supportedCiphers = ciphersuite_default}
            }
    }

withTestService :: (MQTTGRPCClient -> IO ()) -> IO ()
withTestService k = do
  Async.withAsync runTestService \_ -> do
    withGRPCClient (clientConfigGRPC 50051) \clientGRPC -> do
      methods <- testServiceRemoteClientMethodMap clientGRPC
      Async.withAsync (runRemoteClient logger remoteClientConfig testBaseTopic methods) \_ -> do
        sleep 1
        withMQTTGRPCClient logger clientConfig k
  where
    logger :: Logger
    logger = Logger print Silent

    remoteClientConfig :: MQTTGRPCConfig
    remoteClientConfig = configGrpcMqtt{_connID = "test_adaptor"}

    clientConfig :: MQTTGRPCConfig
    clientConfig = configGrpcMqtt{_connID = "test_client"}

testNormalCall :: Property
testNormalCall = withTests 1 $ property do
  let message = Message.TwoInts 4 6
  let request = MQTTNormalRequest message 5 []
  response <- liftIO (makeNormalCall request)

  case response of
    MQTTError err -> do
      annotateShow err
      failure
    GRPCResult (ClientErrorResponse err) -> do
      annotateShow err
      failure
    GRPCResult (ClientNormalResponse result _ _ status _) -> do
      annotateShow result
      result === Message.OneInt 10
      status === StatusOk

testClientStreamCall :: Property
testClientStreamCall = withTests 1 $ property do
  let request = MQTTWriterRequest 5 [("a_little_bit", "of_initial_metadata")] clientStream
  response <- liftIO (makeClientStreamCall request)

  case response of
    MQTTError err -> do
      annotateShow err
      failure
    GRPCResult (ClientErrorResponse err) -> do
      annotateShow err
      failure
    GRPCResult (ClientWriterResponse result _ _ status _) -> do
      annotateShow result
      status === StatusOk
  where
    clientStream :: StreamSend OneInt -> IO ()
    clientStream send = do
      let ints :: [OneInt]
          ints = map Message.OneInt [1 .. 3]
       in traverse_ send ints

testServerStreamCall :: Property
testServerStreamCall = withTests 1 $ property do
  let testInput = Message.SSRqt "Alice" 2
  let request = MQTTReaderRequest testInput 10 [("a_little_bit", "of_initial_metadata")] serverStream
  liftIO (makeServerStreamCall request)
  where
    serverStream :: MetadataMap -> StreamRecv SSRpy -> IO ()
    serverStream metadata recv =
      let loop :: IO ()
          loop = do
            response <- recv
            case response of
              Left err -> do
                error (show err)
              Right Nothing -> do
                pure ()
              Right (Just msg) -> do
                print msg
                loop
       in loop

testBiDiCall :: Property
testBiDiCall = withTests 1 $ property do
  let request = MQTTBiDiRequest 5 [("a_little_bit", "of_initial_metadata")] bidiStream
  liftIO (makeBiDiCall request)
  where
    bidiStream :: MetadataMap -> StreamRecv BiRqtRpy -> StreamSend BiRqtRpy -> WritesDone -> IO ()
    bidiStream metadata recv send done = do
      let testSend = do
            eithers <-
              sequence
                [ send (Message.BiRqtRpy "Alice1")
                , send (Message.BiRqtRpy "Alice2")
                , send (Message.BiRqtRpy "Alice3")
                , done
                ]
            case sequence @[] eithers of
              Left err -> error (show err)
              Right _ -> pure ()

      Async.concurrently_
        (serverStream metadata recv)
        testSend

    serverStream :: MetadataMap -> StreamRecv BiRqtRpy -> IO ()
    serverStream metadata recv =
      let loop :: IO ()
          loop = do
            response <- recv
            case response of
              Left err -> do
                error (show err)
              Right Nothing -> do
                pure ()
              Right (Just msg) -> do
                print msg
                loop
       in loop

makeNormalCall ::
  MQTTRequest 'Normal TwoInts OneInt ->
  IO (MQTTResult 'Normal OneInt)
makeNormalCall request = do
  var <- newEmptyTMVarIO

  withTestService \clientMQTT -> do
    let TestService{testServiceNormal} = testServiceMqttClient clientMQTT testBaseTopic
    thread <- Async.async (testServiceNormal request)
    result <- Async.wait thread
    atomically (putTMVar var result)

  atomically (readTMVar var)

makeClientStreamCall ::
  MQTTRequest 'ClientStreaming OneInt OneInt ->
  IO (MQTTResult 'ClientStreaming OneInt)
makeClientStreamCall request = do
  var <- newEmptyTMVarIO

  withTestService \clientMQTT -> do
    let TestService{testServiceClientStream} = testServiceMqttClient clientMQTT testBaseTopic
    thread <- Async.async (testServiceClientStream request)
    result <- Async.wait thread
    atomically (putTMVar var result)

  atomically (readTMVar var)

makeServerStreamCall :: MQTTRequest 'ServerStreaming SSRqt SSRpy -> IO ()
makeServerStreamCall request = do
  withTestService \clientMQTT -> do
    let TestService{testServiceServerStream} = testServiceMqttClient clientMQTT testBaseTopic
    Async.async (testServiceServerStream request)
    pure ()

makeBiDiCall :: MQTTRequest 'BiDiStreaming BiRqtRpy BiRqtRpy -> IO ()
makeBiDiCall request = do
  withTestService \clientMQTT -> do
    let TestService{testServiceBiDi} = testServiceMqttClient clientMQTT testBaseTopic
    Async.async (testServiceBiDi request)
    pure ()
