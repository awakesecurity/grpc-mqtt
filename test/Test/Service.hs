{-# LANGUAGE CPP #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TypeApplications #-}

-- |
module Test.Service
  ( tests,
  )
where

#if !MIN_VERSION_proto3_suite(0,4,3)
#define testServicenormalCall testServiceNormalCall
#endif

--------------------------------------------------------------------------------

import Test.Tasty (TestTree, after, testGroup)
import Test.Tasty qualified as Test
import Test.Tasty.HUnit (assertFailure, (@?=))

--------------------------------------------------------------------------------

import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async

import Data.Sequence qualified as Seq

import Network.GRPC.HighLevel qualified as GRPC
import Network.GRPC.HighLevel.Client
  ( ClientResult (..),
    MetadataMap,
    StreamRecv,
    StreamSend,
    WritesDone,
  )
import Network.GRPC.HighLevel.Client qualified as GRPC.Client
import Network.GRPC.HighLevel.Generated (StatusCode (StatusOk), withGRPCClient)
import Network.GRPC.Unsafe qualified as GRPC.Unsafe

import Network.MQTT.Client (QoS (QoS1), publishq, Topic)

import Relude hiding (reader)

import Turtle (NominalDiffTime, sleep)

--------------------------------------------------------------------------------

import Test.Suite.Config qualified as Suite
import Test.Suite.Fixture (Fixture)
import Test.Suite.Fixture qualified as Suite

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Client (MQTTGRPCClient, withMQTTGRPCClient)
import Network.GRPC.MQTT.Client qualified as GRPC.MQTT.Client
import Network.GRPC.MQTT.Core (MQTTGRPCConfig (..))
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

import Data.ByteString qualified as ByteString
import Proto.Message (BiDiRequestReply, OneInt, StreamReply)
import Proto.Message qualified as Message
import Proto.Service
  ( TestService
      ( testServiceBatchBiDiStreamCall,
        testServiceBatchClientStreamCall,
        testServiceBatchServerStreamCall,
        testServiceBiDiStreamCall,
        testServiceClientStreamCall,
        testServiceServerStreamCall,
        testServicenormalCall
      ),
    testServicecallLongBytes,
  )

import Hedgehog (evalIO, property, withTests, (===))
import Hedgehog qualified
import Test.Suite.MQTT (withTestMQTTGRPCClient, withPartialTestMQTTGRPCClient)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Service"
    [ withTestMQTTGRPCClient \initClient topic ->
        testGroup 
          "Pass"
          [ testNormalCall initClient topic
          , after Test.AllSucceed "Unary.Normal" (testLongBytes initClient topic)
          , after Test.AllSucceed "Unary.LongBytes" (testClientStreamCall initClient topic)
          , after Test.AllSucceed "Client.Unbatched" (testBatchClientStreamCall initClient topic)
          , after Test.AllSucceed "Client.Batched" (testServerStreamCall initClient topic)
          , after Test.AllSucceed "Server.Unbatched" (testBatchServerStreamCall initClient topic)
          , after Test.AllSucceed "Server.Batched" (testBiDiStreamCall initClient topic)
          , after Test.AllSucceed "BiDi.Unbatched" (testBatchBiDiStreamCall initClient topic)
          ]
    , testGroup 
        "Fail" 
        [ after Test.AllSucceed "Pass" testTimeoutClientNoGRPC 
        , after Test.AllSucceed "Timeout" testPublishBadTopic
        ]
    ]

withTestService :: (Async () -> IO a) -> Fixture a
withTestService k = do
  svcOptions <- Suite.askServiceOptions
  -- liftIO (print $ GRPC.optMaxReceiveMessageLength svcOptions)
  liftIO (Async.withAsync (newTestService svcOptions) k)

-- | Interval to wait for the remote client to be fully ready
remoteClientWaitSecs :: NominalDiffTime
remoteClientWaitSecs = 1

withServiceFixture :: (MQTTGRPCConfig -> MQTTGRPCClient -> IO a) -> Fixture a
withServiceFixture k = do
  configGRPC <- Suite.askConfigClientGRPC
  remoteConfig <- Suite.askRemoteConfigMQTT
  clientConfig <- Suite.askClientConfigMQTT
  baseTopic <- asks Suite.testConfigBaseTopic

  withTestService \server -> do
    withGRPCClient configGRPC \client -> do
      methods <- testServiceRemoteClientMethodMap client
      Async.withAsync (runRemoteClient logger remoteConfig baseTopic methods) \remote -> do
        Async.link2 server remote
        sleep remoteClientWaitSecs
        withMQTTGRPCClient logger clientConfig (k clientConfig)
  where
    logger :: Logger
    logger = Logger print GRPC.MQTT.Logging.Silent

--------------------------------------------------------------------------------

testNormalCall :: IO MQTTGRPCClient -> Topic -> TestTree
testNormalCall initClient topic =
  (testProperty "Unary.Normal" . withTests 1 . property) do
    let msg = Message.TwoInts 5 10
    let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 mempty

    client <- Hedgehog.evalIO initClient
    result <- Hedgehog.evalIO (testServicenormalCall (testServiceMqttClient client topic) rqt)

    case result of
      MQTTError exn -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientErrorResponse exn) -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientNormalResponse oneInt _ _ status _) -> do
        status === StatusOk
        oneInt === Message.OneInt 15

testLongBytes :: IO MQTTGRPCClient -> Topic -> TestTree
testLongBytes initClient topic =
  (testProperty "Unary.LongBytes" . withTests 1 . property) do 
    let msg = Message.OneInt 64
    let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 []

    client <- Hedgehog.evalIO initClient
    result <- Hedgehog.evalIO (testServicecallLongBytes (testServiceMqttClient client topic) rqt)

    case result of
      MQTTError exn -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientErrorResponse exn) -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientNormalResponse rsp _ _ status _) -> do
        status === StatusOk
        rsp === Message.BytesResponse (ByteString.replicate (1_000_000 * 64) 1)

--------------------------------------------------------------------------------

testClientStreamCall :: IO MQTTGRPCClient -> Topic -> TestTree
testClientStreamCall initClient topic = 
  (testProperty "Client.Unbatched" . withTests 1 . property) do 
    let rqt = GRPC.MQTT.MQTTWriterRequest 30 mempty (clientStreamHandler ints)

    client <- Hedgehog.evalIO initClient
    result <- Hedgehog.evalIO (testServiceClientStreamCall (testServiceMqttClient client topic) rqt)

    case result of
      MQTTError exn -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientErrorResponse exn) -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientWriterResponse rsp _ _ status _) -> do
        status === StatusOk
        rsp === expectation
  where 
    expectation :: Maybe OneInt
    expectation = Just (foldr plusOneInt (Message.OneInt 0) ints)
    
    plusOneInt :: OneInt -> OneInt -> OneInt
    plusOneInt (Message.OneInt x) (Message.OneInt y) = Message.OneInt (x + y)

    ints :: [OneInt]
    ints = map Message.OneInt [1 .. 5]

testBatchClientStreamCall :: IO MQTTGRPCClient -> Topic -> TestTree
testBatchClientStreamCall initClient topic = 
  (testProperty "Client.Batched" . withTests 1 . property) do 
    let rqt = GRPC.MQTT.MQTTWriterRequest 10 mempty (clientStreamHandler ints)

    client <- Hedgehog.evalIO initClient
    result <- Hedgehog.evalIO (testServiceBatchClientStreamCall (testServiceMqttClient client topic) rqt)

    case result of
      MQTTError exn -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientErrorResponse exn) -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientWriterResponse rsp _ _ status _) -> do
        status === StatusOk
        rsp === expectation
  where 
    expectation :: Maybe OneInt
    expectation = Just (foldr plusOneInt (Message.OneInt 0) ints)
    
    plusOneInt :: OneInt -> OneInt -> OneInt
    plusOneInt (Message.OneInt x) (Message.OneInt y) = Message.OneInt (x + y)

    ints :: [OneInt]
    ints = map Message.OneInt [1 .. 5]

--------------------------------------------------------------------------------

testServerStreamCall :: IO MQTTGRPCClient -> Topic -> TestTree
testServerStreamCall initClient topic = 
  (testProperty "Server.Unbatched" . withTests 1 . property) do 
    buffer <- liftIO $ newIORef Seq.empty

    let msg = Message.StreamRequest "Alice" 100
    let rqt = MQTTReaderRequest msg 100 mempty (serverStreamHandler buffer)

    client <- Hedgehog.evalIO initClient
    result <- Hedgehog.evalIO (testServiceServerStreamCall (testServiceMqttClient client topic) rqt)

    case result of 
      MQTTError exn -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientErrorResponse exn) -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientReaderResponse _ status _) -> do
        actual <- readIORef buffer
        actual === expected
        status === StatusOk
  where 
    expected :: Seq StreamReply
    expected = fmap (\(n :: Int) -> Message.StreamReply ("Alice" <> show n)) (Seq.fromList [1 .. 100])

testBatchServerStreamCall :: IO MQTTGRPCClient -> Topic -> TestTree
testBatchServerStreamCall initClient topic = 
  (testProperty "Server.Batched" . withTests 1 . property) do 
    buffer <- liftIO $ newIORef Seq.empty

    let msg = Message.StreamRequest "Alice" 100
    let rqt = MQTTReaderRequest msg 300 mempty (serverStreamHandler buffer)

    client <- Hedgehog.evalIO initClient
    result <- Hedgehog.evalIO (testServiceBatchServerStreamCall (testServiceMqttClient client topic) rqt)

    case result of 
      MQTTError exn -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientErrorResponse exn) -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientReaderResponse _ status _) -> do
        actual <- readIORef buffer
        actual === expected
        status === StatusOk
  where 
    expected :: Seq StreamReply
    expected = fmap (\(n :: Int) -> Message.StreamReply ("Alice" <> show n)) (Seq.fromList [1 .. 100])

--------------------------------------------------------------------------------

testBiDiStreamCall :: IO MQTTGRPCClient -> Topic -> TestTree
testBiDiStreamCall initClient topic = 
  (testProperty "BiDi.Unbatched" . withTests 1 . property) do 
    let rqt = MQTTBiDiRequest 10 mempty bidiStreamHandler

    client <- Hedgehog.evalIO initClient
    result <- Hedgehog.evalIO (testServiceBiDiStreamCall (testServiceMqttClient client topic) rqt)

    case result of
      MQTTError exn -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientErrorResponse exn) -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientBiDiResponse _ status _) -> do
        status === StatusOk

testBatchBiDiStreamCall :: IO MQTTGRPCClient -> Topic -> TestTree
testBatchBiDiStreamCall initClient topic = 
  (testProperty "BiDi.Batched" . withTests 1 . property) do 
    let rqt = MQTTBiDiRequest 15 mempty bidiStreamHandler

    client <- Hedgehog.evalIO initClient
    result <- Hedgehog.evalIO (testServiceBatchBiDiStreamCall (testServiceMqttClient client topic) rqt)

    case result of
      MQTTError exn -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientErrorResponse exn) -> do
        Hedgehog.footnoteShow exn
        Hedgehog.failure
      GRPCResult (ClientBiDiResponse _ status _) -> do
        status === StatusOk

--------------------------------------------------------------------------------

testTreeErrors :: TestTree
testTreeErrors =
  let missing :: TestTree
      missing = Suite.testFixture "Test.Service.Errors.Missing" testMissingClientMethod
   in testGroup
        "Test.Service.Errors"
        [ 
          after Test.AllSucceed "Errors.Timeout" missing
        ]

testTimeoutClientNoGRPC :: TestTree
testTimeoutClientNoGRPC = 
  withPartialTestMQTTGRPCClient \initClient topic -> 
    (testProperty "Timeout.gRPC" . withTests 1 . property) do 
      let msg = Message.TwoInts 5 10
      let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 mempty

      client <- Hedgehog.evalIO initClient
      result <- Hedgehog.evalIO (testServicenormalCall (testServiceMqttClient client topic) rqt)

      case result of
        MQTTError exn -> do
          Hedgehog.footnoteShow exn
          Hedgehog.failure
        GRPCResult (ClientErrorResponse exn) -> do
          Hedgehog.footnoteShow exn
          exn === expectation
        GRPCResult (ClientNormalResponse rsp _ _ _ _) -> do
          Hedgehog.footnoteShow rsp
          Hedgehog.failure
  where
    expectation :: GRPC.Client.ClientError
    expectation = GRPC.Client.ClientIOError GRPC.GRPCIOTimeout

testMissingClientMethod :: Fixture ()
testMissingClientMethod = do
  configGRPC <- Suite.askConfigClientGRPC
  remoteConfig <- Suite.askRemoteConfigMQTT
  clientConfig <- Suite.askClientConfigMQTT
  baseTopic <- asks Suite.testConfigBaseTopic

  rsp <- withTestService \_ -> do
    withGRPCClient configGRPC \_ -> do
      -- The critical change in this service setup is in passing a @mempty@
      -- MethodMap to the remote client. This test is ensuring that this
      -- will cause a failure upon when the remote client attempts to handle
      -- the non-existent request.
      let remoteClient = runRemoteClient logger remoteConfig baseTopic mempty
      Async.withAsync remoteClient \_ -> do
        sleep remoteClientWaitSecs
        withMQTTGRPCClient logger clientConfig \clientMQTT -> do
          let msg = Message.TwoInts 5 10
          let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 mempty
          testServicenormalCall (testServiceMqttClient clientMQTT baseTopic) rqt

  liftIO case rsp of
    MQTTError err -> do
      assertFailure (show err)
    GRPCResult (ClientNormalResponse result _ _ _ _) -> do
      assertFailure (show result)
    GRPCResult (ClientErrorResponse err) ->
      err @?= expectation
  where
    logger :: Logger
    logger = Logger print GRPC.MQTT.Logging.Debug

    expectation :: GRPC.Client.ClientError
    expectation = GRPC.Client.ClientIOError (GRPC.GRPCIOCallError GRPC.Unsafe.CallError)

testPublishBadTopic :: TestTree 
testPublishBadTopic = do
  withTestMQTTGRPCClient \initClient topic -> 
    (testProperty "Bad-Topic" . withTests 1 . property) do 
      let msg = Message.TwoInts 5 10
      let rqt = GRPC.MQTT.MQTTNormalRequest msg 5 mempty

      client <- Hedgehog.evalIO initClient

      -- Send a malformed message to an unknown topic
      Hedgehog.evalIO (publishq (GRPC.MQTT.Client.mqttClient client) (topic <> "bad") "blah" False QoS1 [])

      -- Make a well-formed request to ensure the previous request did not
      -- take down the service
      result <- Hedgehog.evalIO (testServicenormalCall (testServiceMqttClient client topic) rqt)

      case result of
        MQTTError exn -> do
          Hedgehog.footnoteShow exn
          Hedgehog.failure
        GRPCResult (ClientErrorResponse exn) -> do
          Hedgehog.footnoteShow exn
          Hedgehog.failure
        GRPCResult (ClientNormalResponse rsp _ _ _ _) -> do
          Hedgehog.footnoteShow rsp
          rsp === Message.OneInt 15

--------------------------------------------------------------------------------

-- checkNormalResponse :: TwoInts -> MQTTResult 'Normal OneInt -> Fixture ()
-- checkNormalResponse (Message.TwoInts x y) rsp =
--   liftIO case rsp of
--     MQTTError err -> do
--       assertFailure (show err)
--     GRPCResult (ClientErrorResponse err) -> do
--       assertFailure (show err)
--     GRPCResult (ClientNormalResponse result _ _ status _) -> do
--       status @?= StatusOk
--       result @?= expectation
--   where
--     expectation :: OneInt
--     expectation = Message.OneInt (x + y)

--------------------------------------------------------------------------------

clientStreamHandler :: [OneInt] -> GRPC.Client.StreamSend OneInt -> IO ()
clientStreamHandler ints send =
  forM_ ints \int -> do
    send int

serverStreamHandler ::
  IORef (Seq StreamReply) ->
  MetadataMap ->
  StreamRecv StreamReply ->
  IO ()
serverStreamHandler buffer _ recv =
  fix \loop -> do
    recieved <- recv
    case recieved of
      Left err -> error (show err)
      Right Nothing -> pure ()
      Right (Just reply) -> do
        modifyIORef buffer (Seq.|> reply)
        loop

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
          @[]
          [ send (Message.BiDiRequestReply "Alice1Alice1Alice1")
          , send (Message.BiDiRequestReply "Alice2")
          , send (Message.BiDiRequestReply "Alice3Alice3Alice3")
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
