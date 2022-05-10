{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ImplicitPrelude #-}

-- |
module Test.Service
  ( tests,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (annotateShow, evalIO, failure, (===))

import Test.Tasty (TestTree, testGroup)

--------------------------------------------------------------------------------

import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async

import Control.Monad.Reader (asks)

import Data.Function (fix)

import Network.GRPC.HighLevel qualified as GRPC
import Network.GRPC.HighLevel.Client
  ( ClientResult
      ( ClientBiDiResponse,
        ClientErrorResponse,
        ClientNormalResponse,
        ClientReaderResponse,
        ClientWriterResponse
      ),
    MetadataMap,
    StreamRecv,
    StreamSend,
    WritesDone,
  )
import Network.GRPC.HighLevel.Client qualified as GRPC.Client
import Network.GRPC.HighLevel.Generated
  ( GRPCMethodType (BiDiStreaming, ClientStreaming, Normal, ServerStreaming),
    StatusCode (StatusOk),
    withGRPCClient,
  )
import Network.GRPC.Unsafe qualified as GRPC.Unsafe

import Network.MQTT.Client (publishq, QoS (QoS1))

import Turtle (sleep)

--------------------------------------------------------------------------------

import Test.Suite.Config qualified as Suite
import Test.Suite.Fixture (Fixture, FixtureT)
import Test.Suite.Fixture qualified as Suite

import Test.Message.Gen qualified as Gen
import Test.Request.Gen qualified as Gen

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Client (MQTTGRPCClient, withMQTTGRPCClient)
import Network.GRPC.MQTT.Client qualified as GRPC.MQTT.Client
import Network.GRPC.MQTT.Core
import Network.GRPC.MQTT.Logging (Logger (Logger))
import Network.GRPC.MQTT.Logging qualified as GRPC.MQTT.Logging
import Network.GRPC.MQTT.RemoteClient (runRemoteClient)
import Network.GRPC.MQTT.Types
  ( MQTTRequest (MQTTBiDiRequest, MQTTReaderRequest),
    MQTTResult (GRPCResult, MQTTError),
  )
import Network.GRPC.MQTT.Types qualified as GRPC.MQTT

import Test.Proto.Clients (testServiceMqttClient)
import Test.Proto.RemoteClients (testServiceRemoteClientMethodMap)
import Test.Proto.Service (newTestService)

import Proto.Message (BiDiRequestReply, OneInt, StreamReply, TwoInts)
import Proto.Message qualified as Message
import Proto.Service
  ( TestService
      ( testServiceBatchBiDiStreamCall,
        testServiceBatchClientStreamCall,
        testServiceBatchServerStreamCall,
        testServiceBiDiStreamCall,
        testServiceClientStreamCall,
        testServiceNormalCall,
        testServiceServerStreamCall
      ),
  )

--------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Test.Service"
    [ Suite.testFixture "Normal RPC Call" testNormalCall
    , testGroup
        "Client Stream Calls"
        [ Suite.testFixture "Unbatched" testClientStreamCall
        , Suite.testFixture "Batched" testBatchClientStreamCall
        ]
    , testGroup
        "Server Stream RPC Calls"
        [ Suite.testFixture "Unbatched" testServerStreamCall
        , Suite.testFixture "Batched" testBatchServerStreamCall
        ]
    , testGroup
        "BiDi Stream RPC Calls"
        [ Suite.testFixture "Unbatched" testBiDiCall
        , Suite.testFixture "Batched" testBatchBiDiCall
        ]
    , testGroup
        "Error Cases"
        [ Suite.testFixture "Missing Client Method" testMissingClientMethod
        , Suite.testFixture "Client Timeout" testClientTimeout
        , Suite.testFixture "Malformed Message" testMalformedMessage
        ]
    ]

withTestService :: (Async () -> IO a) -> FixtureT IO a
withTestService k = do
  svcOptions <- Suite.askServiceOptions
  evalIO (Async.withAsync (newTestService svcOptions) k)

withServiceFixture :: forall a. (MQTTGRPCClient -> IO a) -> FixtureT IO a
withServiceFixture k = do
  configGRPC <- Suite.askConfigClientGRPC
  configMQTT <- Suite.askConfigClientMQTT

  baseTopic <- asks Suite.testConfigBaseTopic

  let remoteConfig = configMQTT{_connID = "test_machine_adaptor"}
  let clientConfig = configMQTT{_connID = "test_machine_client"}

  withTestService \server -> do
    withGRPCClient configGRPC \client -> do
      methods <- testServiceRemoteClientMethodMap client
      Async.withAsync (runRemoteClient logger remoteConfig baseTopic methods) \remote -> do
        Async.link2 server remote
        sleep 1
        withMQTTGRPCClient logger clientConfig k
  where
    logger :: Logger
    logger = Logger print GRPC.MQTT.Logging.Silent

--------------------------------------------------------------------------------

testNormalCall :: Fixture
testNormalCall = Suite.fixture do
  msg <- Suite.forAll Gen.twoInts
  rqt <- Suite.forAll (Gen.normalRequest msg)
  rsp <- makeMethodCall testServiceNormalCall rqt
  annotateShow rqt

  checkNormalResponse msg rsp

testClientStreamCall :: Fixture
testClientStreamCall = Suite.fixture do
  msg <- Suite.forAll (Gen.size'list Gen.oneInt)
  rqt <- Suite.forAll (Gen.clientStreamRequest msg)
  rsp <- makeMethodCall testServiceClientStreamCall rqt
  annotateShow rqt

  checkClientStreamResponse msg rsp

testBatchClientStreamCall :: Fixture
testBatchClientStreamCall = Suite.fixture do
  msg <- Suite.forAll (Gen.size'list Gen.oneInt)
  rqt <- Suite.forAll (Gen.clientStreamRequest msg)
  rsp <- makeMethodCall testServiceBatchClientStreamCall rqt
  annotateShow rqt

  checkClientStreamResponse msg rsp

testServerStreamCall :: Fixture
testServerStreamCall = Suite.fixture do
  let msg = Message.StreamRequest "Alice" 3
  let rqt = MQTTReaderRequest msg 6 mempty serverStreamHandler
  rsp <- makeMethodCall testServiceServerStreamCall rqt
  annotateShow rqt

  checkServerStreamResponse rsp

testBatchServerStreamCall :: Fixture
testBatchServerStreamCall = Suite.fixture do
  let msg = Message.StreamRequest "Alice" 3
  let rqt = MQTTReaderRequest msg 6 mempty serverStreamHandler
  rsp <- makeMethodCall testServiceBatchServerStreamCall rqt
  annotateShow rqt

  checkServerStreamResponse rsp

testBiDiCall :: Fixture
testBiDiCall = Suite.fixture do
  let rqt = MQTTBiDiRequest 10 mempty bidiStreamHandler
  rsp <- makeMethodCall testServiceBiDiStreamCall rqt
  annotateShow rqt

  checkBiDiStreamResponse rsp

testBatchBiDiCall :: Fixture
testBatchBiDiCall = Suite.fixture do
  let rqt = MQTTBiDiRequest 10 mempty bidiStreamHandler
  rsp <- makeMethodCall testServiceBatchBiDiStreamCall rqt
  annotateShow rqt

  checkBiDiStreamResponse rsp

testClientTimeout :: Fixture
testClientTimeout = Suite.fixture do
  configMQTT <- Suite.askConfigClientMQTT
  baseTopic <- asks Suite.testConfigBaseTopic

  let clientConfig = configMQTT{_connID = "test_machine_client"}

  rsp <- evalIO $ withMQTTGRPCClient logger clientConfig \client -> do
    let msg = Message.TwoInts 5 10
    let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 mempty
    testServiceNormalCall (testServiceMqttClient client baseTopic) rqt

  case rsp of
    MQTTError err -> do
      annotateShow err
      failure
    GRPCResult (ClientNormalResponse result _ _ status _) -> do
      annotateShow result
      annotateShow status
      failure
    GRPCResult (ClientErrorResponse err) -> do
      annotateShow err
      err === expectation
  where
    logger :: Logger
    logger = Logger print GRPC.MQTT.Logging.Silent

    expectation :: GRPC.Client.ClientError
    expectation = GRPC.Client.ClientIOError GRPC.GRPCIOTimeout

testMissingClientMethod :: Fixture
testMissingClientMethod = Suite.fixture do
  configGRPC <- Suite.askConfigClientGRPC
  configMQTT <- Suite.askConfigClientMQTT
  baseTopic <- asks Suite.testConfigBaseTopic

  let remoteConfig = configMQTT{_connID = "test_machine_adaptor"}
  let clientConfig = configMQTT{_connID = "test_machine_client"}

  rsp <- withTestService \server -> do
    withGRPCClient configGRPC \_ -> do
      -- The critical change in this service setup is in passing a @mempty@
      -- MethodMap to the remote client. This test is ensuring that this
      -- will cause a failure upon when the remote client attempts to handle
      -- the non-existent request.
      let remoteClient = runRemoteClient logger remoteConfig baseTopic mempty
      Async.withAsync remoteClient \remote -> do
        Async.link2 server remote
        sleep 1
        withMQTTGRPCClient logger clientConfig \clientMQTT -> do
          let msg = Message.TwoInts 5 10
          let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 mempty
          testServiceNormalCall (testServiceMqttClient clientMQTT baseTopic) rqt

  case rsp of
    MQTTError err -> do
      annotateShow err
      failure
    GRPCResult (ClientNormalResponse result _ _ status _) -> do
      annotateShow result
      annotateShow status
      failure
    GRPCResult (ClientErrorResponse err) -> do
      annotateShow err
      err === expectation
  where
    logger :: Logger
    logger = Logger print GRPC.MQTT.Logging.Silent

    expectation :: GRPC.Client.ClientError
    expectation = GRPC.Client.ClientIOError (GRPC.GRPCIOCallError GRPC.Unsafe.CallError)

testMalformedMessage :: Fixture
testMalformedMessage = Suite.fixture do
  configGRPC <- Suite.askConfigClientGRPC
  configMQTT <- Suite.askConfigClientMQTT
  baseTopic <- asks Suite.testConfigBaseTopic

  let remoteConfig = configMQTT{_connID = "test_machine_adaptor"}
  let clientConfig = configMQTT{_connID = "test_machine_client"}

  let msg = Message.TwoInts 5 10
  let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 mempty

  rsp <- withTestService \server -> do
    withGRPCClient configGRPC \clientGRPC -> do
      methods <- testServiceRemoteClientMethodMap clientGRPC
      let remoteClient = runRemoteClient logger remoteConfig baseTopic methods
      Async.withAsync remoteClient \remote -> do
        Async.link2 server remote
        sleep 1
        withMQTTGRPCClient logger clientConfig \clientMQTT -> do
          -- Send a malformed message to an unknown topic
          publishq (GRPC.MQTT.Client.mqttClient clientMQTT) (baseTopic <> "bad") "blah" False QoS1 []

          -- Make a well-formed request to ensure the previous request did not
          -- take down the service
          testServiceNormalCall (testServiceMqttClient clientMQTT baseTopic) rqt

  checkNormalResponse msg rsp
  where
    logger :: Logger
    logger = Logger print GRPC.MQTT.Logging.Silent

--------------------------------------------------------------------------------

checkNormalResponse :: TwoInts -> MQTTResult 'Normal OneInt -> FixtureT IO ()
checkNormalResponse (Message.TwoInts x y) rsp =
  case rsp of
    MQTTError err -> do
      annotateShow err
      failure
    GRPCResult (ClientErrorResponse err) -> do
      annotateShow err
      failure
    GRPCResult (ClientNormalResponse result _ _ status _) -> do
      annotateShow result
      annotateShow status
      status === StatusOk
      result === expectation
  where
    expectation :: OneInt
    expectation = Message.OneInt (x + y)

checkClientStreamResponse ::
  [OneInt] ->
  MQTTResult 'ClientStreaming OneInt ->
  FixtureT IO ()
checkClientStreamResponse ints rsp =
  case rsp of
    MQTTError err -> do
      annotateShow err
      failure
    GRPCResult (ClientErrorResponse err) -> do
      annotateShow err
      failure
    GRPCResult (ClientWriterResponse result _ _ status _) -> do
      annotateShow result
      annotateShow status
      status === StatusOk
      result === expectation
  where
    plusOneInt :: OneInt -> OneInt -> OneInt
    plusOneInt (Message.OneInt x) (Message.OneInt y) = Message.OneInt (x + y)

    expectation :: Maybe OneInt
    expectation = Just (foldr plusOneInt (Message.OneInt 0) ints)

checkServerStreamResponse ::
  MQTTResult 'ServerStreaming StreamReply ->
  FixtureT IO ()
checkServerStreamResponse rsp =
  case rsp of
    MQTTError err -> do
      annotateShow err
      failure
    GRPCResult (ClientErrorResponse err) -> do
      annotateShow err
      failure
    GRPCResult (ClientReaderResponse _ status _) -> do
      annotateShow status
      status === StatusOk

checkBiDiStreamResponse ::
  MQTTResult 'BiDiStreaming BiDiRequestReply ->
  FixtureT IO ()
checkBiDiStreamResponse rsp =
  case rsp of
    MQTTError err -> do
      annotateShow err
      failure
    GRPCResult (ClientErrorResponse err) -> do
      annotateShow err
      failure
    GRPCResult (ClientBiDiResponse _ status _) -> do
      annotateShow status
      status === StatusOk

--------------------------------------------------------------------------------

type Handler s rqt rsp = MQTTRequest s rqt rsp -> IO (MQTTResult s rsp)

makeMethodCall ::
  (TestService MQTTRequest MQTTResult -> Handler s rqt rsp) ->
  MQTTRequest s rqt rsp ->
  FixtureT IO (MQTTResult s rsp)
makeMethodCall method request = do
  baseTopic <- asks Suite.testConfigBaseTopic
  withServiceFixture \client -> do
    method (testServiceMqttClient client baseTopic) request

--------------------------------------------------------------------------------

serverStreamHandler :: MetadataMap -> StreamRecv StreamReply -> IO ()
serverStreamHandler _ recv =
  fix \loop -> do
    recieved <- recv
    case recieved of
      Left err -> error (show err)
      Right Nothing -> pure ()
      Right (Just _) -> loop

bidiStreamHandler ::
  MetadataMap ->
  StreamRecv BiDiRequestReply ->
  StreamSend BiDiRequestReply ->
  WritesDone ->
  IO ()
bidiStreamHandler _ recv send done = do
  Async.concurrently_ sender reader
  where
    sender :: IO ()
    sender = do
      results <-
        sequence
          [ send (Message.BiDiRequestReply "Alice1")
          , send (Message.BiDiRequestReply "Alice2")
          , send (Message.BiDiRequestReply "Alice3")
          , done
          ]
      case sequence results of
        Left err -> error (show err)
        Right _ -> pure ()

    reader :: IO ()
    reader = do
      fix \loop -> do
        recieved <- recv
        case recieved of
          Left err -> error (show err)
          Right Nothing -> pure ()
          Right (Just _) -> loop
