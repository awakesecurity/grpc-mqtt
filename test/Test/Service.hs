{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ImplicitPrelude #-}

-- |
module Test.Service
  ( tests,
  )
where

--------------------------------------------------------------------------------

import Test.Tasty (TestTree, TestName, DependencyType (AllFinish), after, testGroup)
import Test.Tasty.HUnit (assertFailure, (@?=))

--------------------------------------------------------------------------------

import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async

import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
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

import Network.MQTT.Client (QoS (QoS1), publishq)

import Turtle (sleep)

--------------------------------------------------------------------------------

import Test.Suite.Config qualified as Suite
import Test.Suite.Fixture (Fixture)
import Test.Suite.Fixture qualified as Suite

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
  testGroup "Test.Service"
    [ Suite.testFixture "Normal RPC Call" testNormalCall
    , (testGroup "Client Stream Calls" . notParallel)
        [ ("Unbatched", testClientStreamCall)
        , ("Batched", testBatchClientStreamCall)
        ]
    , (testGroup "Server Stream RPC Calls" . notParallel)
        [ ("Unbatched", testServerStreamCall)
        , ("Batched", testBatchServerStreamCall)
        ]
    , (testGroup "BiDi Stream RPC Calls" . notParallel)
        [ ("Unbatched", testBiDiCall)
        , ("Batched", testBatchBiDiCall)
        ]
    , (testGroup "Error Cases" . notParallel)
        [ ("Missing Client Method", testMissingClientMethod)
        , ("Client Timeout", testClientTimeout)
        , ("Malformed Message", testMalformedMessage)
        ]
    ]

notParallel :: [(TestName, Fixture ())] -> [TestTree]
notParallel = foldr f []
  where
    f :: (TestName, Fixture ()) -> [TestTree] -> [TestTree]
    f (name, t) [] = [Suite.testFixture name t]
    f (name, t) (lt : rest) = Suite.testFixture name t : after AllFinish name lt : rest

withTestService :: (Async () -> IO a) -> Fixture a
withTestService k = do
  svcOptions <- Suite.askServiceOptions
  liftIO (Async.withAsync (newTestService svcOptions) k)

withServiceFixture :: String -> (MQTTGRPCClient -> IO a) -> Fixture a
withServiceFixture name k = do
  configGRPC <- Suite.askConfigClientGRPC
  configMQTT <- Suite.askConfigClientMQTT

  baseTopic <- asks Suite.testConfigBaseTopic

  let remoteConfig = configMQTT{_connID = "test_machine_adaptor_" <> name}
  let clientConfig = configMQTT{_connID = "test_machine_client_" <> name}

  withTestService \server -> do
    withGRPCClient configGRPC \client -> do
      methods <- testServiceRemoteClientMethodMap client
      Async.withAsync (runRemoteClient logger remoteConfig baseTopic methods) \remote -> do
        Async.link2 server remote
        sleep 1
        withMQTTGRPCClient logger clientConfig k
  where
    logger :: Logger
    logger = Logger print GRPC.MQTT.Logging.Silent -- Debug

--------------------------------------------------------------------------------

testNormalCall :: Fixture ()
testNormalCall = do
  let msg = Message.TwoInts 5 10
  let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 mempty
  rsp <- makeMethodCall "normal" testServiceNormalCall rqt

  checkNormalResponse msg rsp

testClientStreamCall :: Fixture ()
testClientStreamCall = do
  let msg = map Message.OneInt [1 .. 5]
  let rqt = GRPC.MQTT.MQTTWriterRequest 5 mempty (clientStreamHandler msg)
  rsp <- makeMethodCall "client_stream" testServiceClientStreamCall rqt

  checkClientStreamResponse msg rsp

testBatchClientStreamCall :: Fixture ()
testBatchClientStreamCall = do
  let msg = map Message.OneInt [1 .. 5]
  let rqt = GRPC.MQTT.MQTTWriterRequest 5 mempty (clientStreamHandler msg)
  rsp <- makeMethodCall "batch_client_stream" testServiceBatchClientStreamCall rqt

  checkClientStreamResponse msg rsp

testServerStreamCall :: Fixture ()
testServerStreamCall = do
  let msg = Message.StreamRequest "Alice" 3
  let rqt = MQTTReaderRequest msg 6 mempty serverStreamHandler
  rsp <- makeMethodCall "server_stream" testServiceServerStreamCall rqt

  checkServerStreamResponse rsp

testBatchServerStreamCall :: Fixture ()
testBatchServerStreamCall = do
  let msg = Message.StreamRequest "Alice" 3
  let rqt = MQTTReaderRequest msg 6 mempty serverStreamHandler
  rsp <- makeMethodCall "batch_server_stream" testServiceBatchServerStreamCall rqt

  checkServerStreamResponse rsp

testBiDiCall :: Fixture ()
testBiDiCall = do
  let rqt = MQTTBiDiRequest 10 mempty bidiStreamHandler
  rsp <- makeMethodCall "bidi" testServiceBiDiStreamCall rqt

  checkBiDiStreamResponse rsp

testBatchBiDiCall :: Fixture ()
testBatchBiDiCall = do
  let rqt = MQTTBiDiRequest 10 mempty bidiStreamHandler
  rsp <- makeMethodCall "batch_bidi" testServiceBatchBiDiStreamCall rqt

  checkBiDiStreamResponse rsp

testClientTimeout :: Fixture ()
testClientTimeout = do
  configMQTT <- Suite.askConfigClientMQTT
  baseTopic <- asks Suite.testConfigBaseTopic

  let clientConfig = configMQTT{_connID = "test_machine_client_timeout"}

  rsp <- liftIO $ withMQTTGRPCClient logger clientConfig \client -> do
    let msg = Message.TwoInts 5 10
    let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 mempty
    testServiceNormalCall (testServiceMqttClient client baseTopic) rqt

  liftIO case rsp of
    MQTTError err -> do
      assertFailure (show err)
    GRPCResult (ClientNormalResponse result _ _ _ _) -> do
      assertFailure (show result)
    GRPCResult (ClientErrorResponse err) -> do
      err @?= expectation
  where
    logger :: Logger
    logger = Logger print GRPC.MQTT.Logging.Silent

    expectation :: GRPC.Client.ClientError
    expectation = GRPC.Client.ClientIOError GRPC.GRPCIOTimeout

testMissingClientMethod :: Fixture ()
testMissingClientMethod = do
  configGRPC <- Suite.askConfigClientGRPC
  configMQTT <- Suite.askConfigClientMQTT
  baseTopic <- asks Suite.testConfigBaseTopic

  let remoteConfig = configMQTT{_connID = "test_machine_adaptor_missing_method"}
  let clientConfig = configMQTT{_connID = "test_machine_client_missing_method"}

  rsp <- withTestService \_ -> do
    withGRPCClient configGRPC \_ -> do
      -- The critical change in this service setup is in passing a @mempty@
      -- MethodMap to the remote client. This test is ensuring that this
      -- will cause a failure upon when the remote client attempts to handle
      -- the non-existent request.
      let remoteClient = runRemoteClient logger remoteConfig baseTopic mempty
      Async.withAsync remoteClient \_ -> do
        sleep 1
        withMQTTGRPCClient logger clientConfig \clientMQTT -> do
          let msg = Message.TwoInts 5 10
          let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 mempty
          testServiceNormalCall (testServiceMqttClient clientMQTT baseTopic) rqt

  liftIO case rsp of
    MQTTError err -> do
      assertFailure (show err)
    GRPCResult (ClientNormalResponse result _ _ _ _) -> do
      assertFailure (show result)
    GRPCResult (ClientErrorResponse err) ->
      err @?= expectation
  where
    logger :: Logger
    logger = Logger print GRPC.MQTT.Logging.Silent

    expectation :: GRPC.Client.ClientError
    expectation = GRPC.Client.ClientIOError (GRPC.GRPCIOCallError GRPC.Unsafe.CallError)

testMalformedMessage :: Fixture ()
testMalformedMessage = do
  configGRPC <- Suite.askConfigClientGRPC
  configMQTT <- Suite.askConfigClientMQTT
  baseTopic <- asks Suite.testConfigBaseTopic

  let remoteConfig = configMQTT{_connID = "test_machine_adaptor_malformed"}
  let clientConfig = configMQTT{_connID = "test_machine_client_malformed"}

  let msg = Message.TwoInts 5 10
  let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 mempty

  rsp <- withTestService \_ -> do
    withGRPCClient configGRPC \clientGRPC -> do
      methods <- testServiceRemoteClientMethodMap clientGRPC
      let remoteClient = runRemoteClient logger remoteConfig baseTopic methods
      Async.withAsync remoteClient \_ -> do
        withMQTTGRPCClient logger clientConfig \clientMQTT -> do
          -- Send a malformed message to an unknown topic
          publishq (GRPC.MQTT.Client.mqttClient clientMQTT) (baseTopic <> "bad") "blah" False QoS1 []
          sleep 1

          -- Make a well-formed request to ensure the previous request did not
          -- take down the service
          testServiceNormalCall (testServiceMqttClient clientMQTT baseTopic) rqt

  checkNormalResponse msg rsp
  where
    logger :: Logger
    logger = Logger print GRPC.MQTT.Logging.Debug

-- logger = Logger print GRPC.MQTT.Logging.Silent

--------------------------------------------------------------------------------

checkNormalResponse :: TwoInts -> MQTTResult 'Normal OneInt -> Fixture ()
checkNormalResponse (Message.TwoInts x y) rsp =
  liftIO case rsp of
    MQTTError err -> do
      assertFailure (show err)
    GRPCResult (ClientErrorResponse err) -> do
      assertFailure (show err)
    GRPCResult (ClientNormalResponse result _ _ status _) -> do
      status @?= StatusOk
      result @?= expectation
  where
    expectation :: OneInt
    expectation = Message.OneInt (x + y)

checkClientStreamResponse ::
  [OneInt] ->
  MQTTResult 'ClientStreaming OneInt ->
  Fixture ()
checkClientStreamResponse ints rsp =
  liftIO case rsp of
    MQTTError err -> do
      assertFailure (show err)
    GRPCResult (ClientErrorResponse err) -> do
      assertFailure (show err)
    GRPCResult (ClientWriterResponse result _ _ status _) -> do
      status @?= StatusOk
      result @?= expectation
  where
    plusOneInt :: OneInt -> OneInt -> OneInt
    plusOneInt (Message.OneInt x) (Message.OneInt y) = Message.OneInt (x + y)

    expectation :: Maybe OneInt
    expectation = Just (foldr plusOneInt (Message.OneInt 0) ints)

checkServerStreamResponse ::
  MQTTResult 'ServerStreaming StreamReply ->
  Fixture ()
checkServerStreamResponse rsp =
  liftIO case rsp of
    MQTTError err -> do
      assertFailure (show err)
    GRPCResult (ClientErrorResponse err) -> do
      assertFailure (show err)
    GRPCResult (ClientReaderResponse _ status _) -> do
      status @?= StatusOk

checkBiDiStreamResponse ::
  MQTTResult 'BiDiStreaming BiDiRequestReply ->
  Fixture ()
checkBiDiStreamResponse rsp =
  liftIO case rsp of
    MQTTError err -> do
      assertFailure (show err)
    GRPCResult (ClientErrorResponse err) -> do
      assertFailure (show err)
    GRPCResult (ClientBiDiResponse _ status _) -> do
      status @?= StatusOk

--------------------------------------------------------------------------------

type Handler s rqt rsp = MQTTRequest s rqt rsp -> IO (MQTTResult s rsp)

makeMethodCall ::
  String ->
  (TestService MQTTRequest MQTTResult -> Handler s rqt rsp) ->
  MQTTRequest s rqt rsp ->
  Fixture (MQTTResult s rsp)
makeMethodCall name method request = do
  baseTopic <- asks Suite.testConfigBaseTopic
  withServiceFixture name \client -> do
    method (testServiceMqttClient client baseTopic) request

--------------------------------------------------------------------------------

clientStreamHandler :: [OneInt] -> GRPC.Client.StreamSend OneInt -> IO ()
clientStreamHandler ints send =
  forM_ ints \int -> do
    send int

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
