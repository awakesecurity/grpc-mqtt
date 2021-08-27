{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE OverloadedLists #-}

module Main where

import Relude

import Test.GRPCServers (
  addHelloHandlers,
  addHelloService,
  infiniteHelloSSHandler,
  multGoodbyeService,
 )
import Test.Helpers (
  assertContains,
  getTestConfig,
  notParallel,
  streamTester,
  testLogger,
  timeit,
 )
import Test.ProtoClients (
  addHelloMqttClient,
  multGoodbyeMqttClient,
 )
import Test.ProtoRemoteClients (
  addHelloRemoteClientMethodMap,
  multGoodbyeRemoteClientMethodMap,
 )

import Network.GRPC.MQTT (
  MessageCallback (SimpleCallback),
  QoS (QoS1),
  SubOptions (_subQoS),
  Topic,
  normalDisconnect,
  publishq,
  subOptions,
  subscribe,
 )
import Network.GRPC.MQTT.Client (
  MQTTGRPCClient (mqttClient),
  withMQTTGRPCClient,
 )
import Network.GRPC.MQTT.Core (
  MQTTGRPCConfig (_connID, _msgCB, mqttMsgSizeLimit),
  connectMQTT,
  toFilter,
 )
import Network.GRPC.MQTT.RemoteClient (runRemoteClient)
import Network.GRPC.MQTT.Sequenced (
  SequenceIdx (SequencedIdx),
  Sequenced (..),
  mkSequencedRead,
 )
import Network.GRPC.MQTT.Types (
  MQTTRequest (MQTTNormalRequest, MQTTReaderRequest, MQTTWriterRequest),
  MQTTResult (GRPCResult, MQTTError),
 )

import Data.Time.Clock (
  diffUTCTime,
  getCurrentTime,
  nominalDiffTimeToSeconds,
 )
import Network.GRPC.HighLevel.Client (
  ClientConfig (..),
  ClientError (ClientIOError),
  ClientResult (..),
  Port,
  StatusCode (StatusOk), StreamSend
 )
import Network.GRPC.HighLevel.Generated (
  GRPCIOError (GRPCIOTimeout),
  ServiceOptions (serverPort),
  defaultServiceOptions,
  withGRPCClient,
 )
import Proto.Test (
  AddHello (AddHello, addHelloHelloSS),
  MultGoodbye (MultGoodbye),
  OneInt (OneInt),
  SSRpy (ssrpyGreeting),
  SSRqt (SSRqt),
  TwoInts (TwoInts),
  addHelloServer,
 )
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (
  Assertion,
  assertBool,
  assertFailure,
  (@?=),
 )
import Turtle (sleep)
import UnliftIO.Async (concurrently_, withAsync)
import UnliftIO.STM (newTChanIO, readTChan, writeTChan)
import UnliftIO.Timeout (timeout)

-- Test gRPC servers
addHelloServerPort :: Port
addHelloServerPort = 50051
runAddHelloServer :: IO ()
runAddHelloServer = addHelloService defaultServiceOptions{serverPort = addHelloServerPort}

multGoodbyeServerPort :: Port
multGoodbyeServerPort = 50052
runMultGoodbyeServer :: IO ()
runMultGoodbyeServer = multGoodbyeService defaultServiceOptions{serverPort = multGoodbyeServerPort}

-- Client
testGrpcClientConfig :: Port -> ClientConfig
testGrpcClientConfig port =
  ClientConfig
    { clientServerHost = "localhost"
    , clientServerPort = port
    , clientArgs = []
    , clientSSLConfig = Nothing
    , clientAuthority = Nothing
    }

-- Test Constants
testClientId :: String
testClientId = "testclient"

testBaseTopic :: Topic
testBaseTopic = "testMachine" <> fromString testClientId

-- Tests
main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" [allTests]

allTests :: TestTree
allTests =
  testGroup "All Tests" $
    notParallel
      [
      --   ("Latency", mqttLatency)
      -- , ("Basic Unary", basicUnary)
      -- , ("Basic Server Streaming", basicServerStreaming)
      ("Basic Client Streaming", basicClientStreaming)
      -- , ("Two Servers", twoServers)
      -- , ("Timeout", testTimeout)
      -- , ("Persistent", persistentMQTT)
      -- , ("Sequenced", testSequenced)
      -- , ("Missing Client Error", missingClientError)
      -- , ("Malformed Topic", malformedMessage)
      -- , ("Packetized", packetizedMesssages)
      ]

persistentMQTT :: Assertion
persistentMQTT = do
  awsConfig <- getTestConfig

  -- Start gRPC Server
  withAsync runAddHelloServer $ \_grpcServerThread -> do
    -- Get gRPC Client
    withGRPCClient (testGrpcClientConfig addHelloServerPort) $ \grpcClient -> do
      methodMap <- addHelloRemoteClientMethodMap grpcClient
      -- Start serverside MQTT adaptor
      withAsync (runRemoteClient testLogger awsConfig{_connID = "testMachineSSAdaptor"} testBaseTopic methodMap) $ \_adaptorThread -> do
        sleep 1
        withMQTTGRPCClient testLogger awsConfig{_connID = testClientId} $ \client -> do
          let AddHello mqttAdd mqttHelloSS _ = addHelloMqttClient client testBaseTopic

          mqttAdd (MQTTNormalRequest (TwoInts 4 6) 2 []) >>= \case
            GRPCResult (ClientNormalResponse result _ _ _ _) -> result @?= OneInt 10
            GRPCResult (ClientErrorResponse err) -> assertFailure $ "add Client error: " <> show err
            MQTTError err -> assertFailure $ "add mqtt error: " <> show err

          mqttAdd (MQTTNormalRequest (TwoInts 1 3) 2 []) >>= \case
            GRPCResult (ClientNormalResponse result _ _ _ _) -> result @?= OneInt 4
            GRPCResult (ClientErrorResponse err) -> assertFailure $ "add Client error: " <> show err
            MQTTError err -> assertFailure $ "add mqtt error: " <> show err

          mqttHelloSS (MQTTReaderRequest (SSRqt "Alice" 3) 20 [] (streamTester (assertContains "Alice" . ssrpyGreeting))) >>= \case
            GRPCResult (ClientReaderResponse _ status _) -> status @?= StatusOk
            GRPCResult (ClientErrorResponse err) -> assertFailure $ "helloSS Client error: " <> show err
            MQTTError err -> assertFailure $ "helloSS mqtt error: " <> show err

          mqttAdd (MQTTNormalRequest (TwoInts 77 15) 2 []) >>= \case
            GRPCResult (ClientNormalResponse result _ _ _ _) -> result @?= OneInt 92
            GRPCResult (ClientErrorResponse err) -> assertFailure $ "add Client error: " <> show err
            MQTTError err -> assertFailure $ "add mqtt error: " <> show err

streamingTermination :: Assertion
streamingTermination = do
  awsConfig <- getTestConfig
  let infHelloService = addHelloServer addHelloHandlers{addHelloHelloSS = infiniteHelloSSHandler}
      gRPCServer = infHelloService defaultServiceOptions{serverPort = addHelloServerPort}
  -- Start gRPC Server
  withAsync gRPCServer $ \_grpcServerThread ->
    -- Get gRPC Client
    withGRPCClient (testGrpcClientConfig addHelloServerPort) $ \grpcClient -> do
      methodMap <- addHelloRemoteClientMethodMap grpcClient

      -- Start serverside MQTT adaptor
      withAsync (runRemoteClient testLogger awsConfig{_connID = "testMachineSSAdaptor"} testBaseTopic methodMap) $ \_adaptorThread -> do
        sleep 1
        withMQTTGRPCClient testLogger awsConfig{_connID = testClientId} $ \client -> do
          let AddHello _ mqttHelloSS _ = addHelloMqttClient client testBaseTopic
          let testInput = SSRqt "Alice" 1
              request = MQTTReaderRequest testInput 20 [] (streamTester (assertContains "Alice" . ssrpyGreeting))

          -- Manually watching session in AWS console
          _ <- timeout 5000000 $ mqttHelloSS request
          sleep 10

testTimeout :: Assertion
testTimeout = do
  awsConfig <- getTestConfig

  withMQTTGRPCClient testLogger awsConfig{_connID = testClientId} $ \client -> do
    let AddHello mqttAdd mqttHelloSS _ = addHelloMqttClient client testBaseTopic

    addResponse <- timeit 3 $ mqttAdd (MQTTNormalRequest (TwoInts 9 16) 2 [])
    case addResponse of
      GRPCResult (ClientErrorResponse err) -> err @?= ClientIOError GRPCIOTimeout
      _ -> assertFailure "WTF"

    helloResponse <- timeit 6 $ do
      mqttHelloSS (MQTTReaderRequest (SSRqt "Alice" 3) 5 [] (streamTester (assertContains "Alice" . ssrpyGreeting)))
    case helloResponse of
      GRPCResult (ClientErrorResponse err) -> err @?= ClientIOError GRPCIOTimeout
      _ -> assertFailure "WTF"

basicUnary :: Assertion
basicUnary = do
  awsConfig <- getTestConfig

  -- Start gRPC Server
  withAsync runAddHelloServer $ \_grpcServerThread -> do
    -- Get gRPC Client
    withGRPCClient (testGrpcClientConfig addHelloServerPort) $ \grpcClient -> do
      methodMap <- addHelloRemoteClientMethodMap grpcClient
      -- Start serverside MQTT adaptor
      withAsync (runRemoteClient testLogger awsConfig{_connID = "testMachineSSAdaptorBU"} testBaseTopic methodMap) $ \_adaptorThread -> do
        --Delay to allow remote client to start receiving MQTT messages
        sleep 1
        withMQTTGRPCClient testLogger awsConfig{_connID = testClientId <> "BU"} $ \client -> do
          let AddHello mqttAdd _ _ = addHelloMqttClient client testBaseTopic
          let testInput = TwoInts 4 6
              expectedResult = OneInt 10
              request = MQTTNormalRequest testInput 5 []

          mqttAdd request >>= \case
            GRPCResult (ClientNormalResponse result _ _ _ _) -> result @?= expectedResult
            GRPCResult (ClientErrorResponse err) -> assertFailure $ "add Client error: " <> show err
            MQTTError err -> assertFailure $ "add mqtt error: " <> show err

basicServerStreaming :: Assertion
basicServerStreaming = do
  awsConfig <- getTestConfig

  -- Start gRPC Server
  withAsync runAddHelloServer $ \_grpcServerThread ->
    -- Get gRPC Client
    withGRPCClient (testGrpcClientConfig addHelloServerPort) $ \grpcClient -> do
      methodMap <- addHelloRemoteClientMethodMap grpcClient

      -- Start serverside MQTT adaptor
      withAsync (runRemoteClient testLogger awsConfig{_connID = "testMachineSSAdaptorSS"} testBaseTopic methodMap) $ \_adaptorThread -> do
        sleep 1
        testHelloCall awsConfig{_connID = testClientId <> "SS"}

basicClientStreaming :: Assertion
basicClientStreaming = do
  awsConfig <- getTestConfig

  -- Start gRPC Server
  withAsync runAddHelloServer $ \_grpcServerThread ->
    -- Get gRPC Client
    withGRPCClient (testGrpcClientConfig addHelloServerPort) $ \grpcClient -> do
      methodMap <- addHelloRemoteClientMethodMap grpcClient

      -- Start serverside MQTT adaptor
      withAsync (runRemoteClient testLogger awsConfig{_connID = "testMachineAdaptorCS"} testBaseTopic methodMap) $ \_adaptorThread -> do
        sleep 1
        testSumCall awsConfig{_connID = testClientId <> "CS"}


packetizedMesssages :: Assertion
packetizedMesssages = do
  awsConfig <- getTestConfig

  -- Start gRPC Server
  withAsync runAddHelloServer $ \_grpcServerThread ->
    -- Get gRPC Client
    withGRPCClient (testGrpcClientConfig addHelloServerPort) $ \grpcClient -> do
      methodMap <- addHelloRemoteClientMethodMap grpcClient

      -- Start serverside MQTT adaptor
      withAsync (runRemoteClient testLogger awsConfig{_connID = "testMachineAdaptorPacketized", mqttMsgSizeLimit = 10} testBaseTopic methodMap) $ \_adaptorThread -> do
        sleep 1
        testAddCall awsConfig{_connID = testClientId <> "Packetized"}
        testHelloCall awsConfig{_connID = testClientId <> "Packetized"}

missingClientError :: Assertion
missingClientError = do
  awsConfig <- getTestConfig

  -- Start gRPC Server
  withAsync runAddHelloServer $ \_grpcServerThread ->
    -- Get gRPC Client
    withGRPCClient (testGrpcClientConfig addHelloServerPort) $ \_grpcClient -> do
      -- Start serverside MQTT adaptor
      withAsync (runRemoteClient testLogger awsConfig{_connID = "testMachineSSAdaptorSS"} testBaseTopic []) $ \_adaptorThread -> do
        sleep 1
        withMQTTGRPCClient testLogger awsConfig{_connID = testClientId <> "SS"} $ \client -> do
          let AddHello _ mqttHelloSS _ = addHelloMqttClient client testBaseTopic
              testInput = SSRqt "Alice" 2
              request = MQTTReaderRequest testInput 5 [("alittlebit", "ofinitialmetadata")] (streamTester (assertContains "Alice" . ssrpyGreeting))

          mqttHelloSS request >>= \case
            MQTTError _err -> pure () -- Success
            _ -> assertFailure "Expected MQTTError"

twoServers :: Assertion
twoServers = do
  awsConfig <- getTestConfig

  -- Start gRPC Server 1
  withAsync runAddHelloServer $ \_grpcServerThread1 ->
    -- Start gRPC Server 2
    withAsync runMultGoodbyeServer $ \_grpcServerThread2 ->
      -- Get gRPC Client 1
      withGRPCClient (testGrpcClientConfig addHelloServerPort) $ \grpcClient1 ->
        -- Get gRPC Client 2
        withGRPCClient (testGrpcClientConfig multGoodbyeServerPort) $ \grpcClient2 -> do
          methodMapAH <- addHelloRemoteClientMethodMap grpcClient1
          methodMapMG <- multGoodbyeRemoteClientMethodMap grpcClient2
          let methodMap = methodMapAH <> methodMapMG
          -- Start serverside MQTT adaptor
          withAsync (runRemoteClient testLogger awsConfig{_connID = "testMachineSSAdaptorTS"} testBaseTopic methodMap) $ \_adaptorThread -> do
            sleep 1
            -- Server 1
            testAddCall awsConfig{_connID = "testclientTS1"}
            testHelloCall awsConfig{_connID = "testclientTS2"}

            -- Server 2
            testMultCall awsConfig{_connID = "testclientTS3"}
            testGoodbyeCall awsConfig{_connID = "testclientTS4"}

testAddCall :: MQTTGRPCConfig -> Assertion
testAddCall cfg = withMQTTGRPCClient testLogger cfg $ \client -> do
  let AddHello mqttAdd _ _ = addHelloMqttClient client testBaseTopic
  let testInput = TwoInts 4 6
      expectedResult = OneInt 10
      request = MQTTNormalRequest testInput 5 []

  mqttAdd request >>= \case
    GRPCResult (ClientNormalResponse result _ _ _ _) -> result @?= expectedResult
    GRPCResult (ClientErrorResponse err) -> assertFailure $ "add Client error: " <> show err
    MQTTError err -> assertFailure $ "add mqtt error: " <> show err

testHelloCall :: MQTTGRPCConfig -> Assertion
testHelloCall cfg = withMQTTGRPCClient testLogger cfg $ \client -> do
  let AddHello _ mqttHelloSS _ = addHelloMqttClient client testBaseTopic
      testInput = SSRqt "Alice" 2
      request = MQTTReaderRequest testInput 5 [("alittlebit", "ofinitialmetadata")] (streamTester (assertContains "Alice" . ssrpyGreeting))

  mqttHelloSS request >>= \case
    GRPCResult (ClientReaderResponse _ status _) -> status @?= StatusOk
    GRPCResult (ClientErrorResponse err) -> assertFailure $ "helloSS Client error: " <> show err
    MQTTError err -> assertFailure $ "helloSS mqtt error: " <> show err

testSumCall :: MQTTGRPCConfig -> Assertion
testSumCall cfg = withMQTTGRPCClient testLogger cfg $ \client -> do
  let AddHello _ _ mqttSumCS = addHelloMqttClient client testBaseTopic
      request = MQTTWriterRequest 5 [("alittlebit", "ofinitialmetadata")] clientStreamTester

  mqttSumCS request >>= \case
    GRPCResult (ClientWriterResponse mres _ _ _status _) -> mres @?= Just (OneInt 6) --status @?= StatusOk
    GRPCResult (ClientErrorResponse err) -> assertFailure $ "sumCS Client error: " <> show err
    MQTTError err -> assertFailure $ "sumCS mqtt error: " <> show err

clientStreamTester :: StreamSend OneInt -> IO ()
clientStreamTester send = do
  eithers <- forM @[] [OneInt 1, OneInt 2, OneInt 3] $ \int -> do
    putStrLn $ "clientStreamTester: " <> show int
    x <- send int
    print x
    pure x
  case sequence eithers of
    Left err -> assertFailure $ "Error while client streaming: " ++ show err
    Right _ -> pure ()

testMultCall :: MQTTGRPCConfig -> Assertion
testMultCall cfg = withMQTTGRPCClient testLogger cfg $ \client -> do
  let MultGoodbye mqttMult _ _ = multGoodbyeMqttClient client testBaseTopic
      testInput = TwoInts 4 6
      expectedResult = OneInt 24
      request = MQTTNormalRequest testInput 5 []

  mqttMult request >>= \case
    GRPCResult (ClientNormalResponse result _ _ _ _) -> result @?= expectedResult
    GRPCResult (ClientErrorResponse err) -> assertFailure $ "mult Client error: " <> show err
    MQTTError err -> assertFailure $ "mult mqtt error: " <> show err

testGoodbyeCall :: MQTTGRPCConfig -> Assertion
testGoodbyeCall cfg = withMQTTGRPCClient testLogger cfg $ \client -> do
  let MultGoodbye _ mqttGoodbyeSS _ = multGoodbyeMqttClient client testBaseTopic
      testInput = SSRqt "Alice" 3
      request = MQTTReaderRequest testInput 10 [] (streamTester (assertContains "Alice" . ssrpyGreeting))

  mqttGoodbyeSS request >>= \case
    GRPCResult (ClientReaderResponse _ status _) -> status @?= StatusOk
    GRPCResult (ClientErrorResponse err) -> assertFailure $ "goodbye Client error: " <> show err
    MQTTError err -> assertFailure $ "goodbye mqtt error: " <> show err

mqttLatency :: Assertion
mqttLatency = do
  let testTopic = "testMachine" <> "messages"
  let subOpts = subOptions{_subQoS = QoS1}

  cfg <- getTestConfig
  done <- newEmptyMVar
  let awsConfig =
        cfg
          { _msgCB = SimpleCallback $ \_ _ _ _ -> getCurrentTime >>= putMVar done
          , _connID = "latencyTester"
          }

  mc <- timeit 1 $ connectMQTT awsConfig

  _ <- timeit 1 $ subscribe mc [(toFilter testTopic, subOpts)] []

  prepubTime <- getCurrentTime
  timeit 1 $ publishq mc testTopic "hello!" False QoS1 []

  serverRecvTime <- takeMVar done
  let seconds = nominalDiffTimeToSeconds $ diffUTCTime serverRecvTime prepubTime
  assertBool ("MQTT client <-> AWS MQTT Broker <-> MQTT Server: " <> show seconds <> "s") $ seconds < 2

  timeit 1 $ normalDisconnect mc

malformedMessage :: Assertion
malformedMessage = do
  awsConfig <- getTestConfig

  -- Start gRPC Server
  withAsync runAddHelloServer $ \_grpcServerThread ->
    -- Get gRPC Client
    withGRPCClient (testGrpcClientConfig addHelloServerPort) $ \grpcClient -> do
      methodMap <- addHelloRemoteClientMethodMap grpcClient
      -- Start serverside MQTT adapter
      withAsync (runRemoteClient testLogger awsConfig{_connID = "errorTesterRC"} testBaseTopic methodMap) $ \_adaptorThread -> do
        sleep 1
        withMQTTGRPCClient testLogger awsConfig{_connID = testClientId <> "errorTester"} $ \client -> do
          -- Publish message for non-existent service
          publishq (mqttClient client) (testBaseTopic <> "grpc" <> "request" <> "bad" <> "service") "blah" False QoS1 []
          sleep 1

          -- Test server is still up and responsive
          let AddHello mqttAdd _ _ = addHelloMqttClient client testBaseTopic
          let testInput = TwoInts 4 6
              expectedResult = OneInt 10
              request = MQTTNormalRequest testInput 5 []

          mqttAdd request >>= \case
            GRPCResult (ClientNormalResponse result _ _ _ _) -> result @?= expectedResult
            GRPCResult (ClientErrorResponse err) -> assertFailure $ "add Client error: " <> show err
            MQTTError err -> assertFailure $ "add mqtt error: " <> show err

data Foo = Foo Natural Char
  deriving stock (Show, Eq)

instance Sequenced Foo where
  type Payload Foo = Char
  seqNum (Foo i _) = SequencedIdx i
  seqPayload (Foo _ c) = c

testSequenced :: Assertion
testSequenced = do
  responseChan <- newTChanIO
  orderedRead <- mkSequencedRead $ readTChan responseChan
  let orderedRead' = seqPayload <$> orderedRead
  let testList = [0, 1, 2, 4, 8, 7, 3, 5, 9, 6]
  let toChar i = toEnum (fromIntegral (i + 97))

  let producer = forM testList $ \i -> do
        atomically $ writeTChan responseChan (Foo i (toChar i))

      consumer = do
        readResults <- replicateM (length testList) orderedRead'
        readResults @?= sort (toChar <$> testList)

  concurrently_ producer consumer
