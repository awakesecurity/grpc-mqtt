{-# LANGUAGE TemplateHaskellQuotes #-}

-- | This module exports "grpc-mqtt" test suite helpers for managing gRPC-MQTT
-- clients and remote clients within tasty tests.
module Test.Suite.MQTT
  ( withTestMQTTGRPCClient,
    withTestRemoteClient,
  )
where

import Network.GRPC.HighLevel.Client (Client)
import Network.GRPC.MQTT (Topic)
import Network.GRPC.MQTT.Client
  ( MQTTGRPCClient,
    connectMQTTGRPC,
    disconnectMQTTGRPC,
  )
import Network.GRPC.MQTT.Core (MQTTGRPCConfig)
import Network.GRPC.MQTT.Logging (Logger (..), Verbosity (..))
import Network.GRPC.MQTT.RemoteClient (runRemoteClient)

import Relude

import Test.Proto.RemoteClients (testServiceRemoteClientMethodMap)

import Test.Suite.Config qualified as Test.Config
import Test.Suite.GRPC (withServer)

import Test.Tasty (TestTree, withResource)

import Text.Printf (printf)

import Turtle (sleep)

import UnliftIO.Async (Async)
import UnliftIO.Async qualified as Async

--------------------------------------------------------------------------------

makeTestLogger :: Logger
makeTestLogger = Logger print Silent

-- | TODO
withTestMQTTGRPCClient :: (IO MQTTGRPCClient -> Topic -> TestTree) -> TestTree
withTestMQTTGRPCClient k =
  withTestRemoteClient \initService -> Test.Config.withTestConfig do
    config <- Test.Config.askConfigMQTT
    topic <- asks Test.Config.testConfigBaseTopic
    pure (withResource (onInit initService config) onDone (`k` topic))
  where
    onInit :: IO (Async ()) -> MQTTGRPCConfig -> IO MQTTGRPCClient
    onInit initService config = do
      printf "withTestMQTTGRPCClient: initializing gRPC-MQTT client.\n"
      void initService
      sleep 1
      connectMQTTGRPC makeTestLogger config

    onDone :: MQTTGRPCClient -> IO ()
    onDone client = do
      printf "withTestMQTTGRPCClient: disconnecting gRPC-MQTT client.\n"
      disconnectMQTTGRPC client

-- | TODO
withTestRemoteClient :: (IO (Async ()) -> TestTree) -> TestTree
withTestRemoteClient k =
  withServer \initGrpc initGrpcClient -> Test.Config.withTestConfig do
    config <- Test.Config.askRemoteConfigMQTT
    topic <- Test.Config.testConfigBaseTopic
    pure (withResource (onInit initGrpc initGrpcClient config topic) onDone k)
  where
    onInit :: IO (Async ()) -> IO Client -> MQTTGRPCConfig -> Topic -> IO (Async ())
    onInit initGrpc initGrpcClient config topic = do
      printf "withTestRemoteClient: initializing gRPC-MQTT remote client.\n"
      void initGrpc
      client <- initGrpcClient
      method <- testServiceRemoteClientMethodMap client
      Async.async (runRemoteClient makeTestLogger config topic method)

    onDone :: Async () -> IO ()
    onDone thread = do
      printf "withTestRemoteClient: disconnecting gRPC-MQTT remote client.\n"
      -- better error handling/async polling
      Async.cancel thread