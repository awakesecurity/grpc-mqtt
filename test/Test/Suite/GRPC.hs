{-# LANGUAGE TemplateHaskellQuotes #-}

-- | This module exports "grpc-mqtt" test suite helpers for managing gRPC
-- servers within tasty tests.
module Test.Suite.GRPC
  ( withServer, 
    -- withTestService,
    -- withTestClient,
    -- withTestGRPC,
  )
where

import Network.GRPC.LowLevel.Client qualified as GRPC
import Network.GRPC.HighLevel (ServiceOptions)
import Network.GRPC.LowLevel.GRPC (GRPC)
import Network.GRPC.LowLevel.GRPC qualified as GRPC

import Relude

import Test.Proto.Service (newTestService)

import Test.Suite.Config qualified as Test.Config

import Test.Tasty (TestTree, withResource)

import Text.Printf (printf)

import UnliftIO.Async (Async)
import UnliftIO.Async qualified as Async

--------------------------------------------------------------------------------

withServer :: (IO (Async ()) -> IO GRPC.Client -> TestTree) -> TestTree
withServer k = withTestService (withTestClient . k)

-- | TODO
withTestService :: (IO (Async ()) -> TestTree) -> TestTree
withTestService k =
  Test.Config.withTestConfig do
    serviceOptions <- Test.Config.askServiceOptions
    pure (withResource (onInit serviceOptions) onDone k)
  where
    onInit :: ServiceOptions -> IO (Async ())
    onInit serviceOptions = do
      printf "withTestService: initializing gRPC test server.\n"
      Async.async (newTestService serviceOptions)

    onDone :: Async () -> IO ()
    onDone thread = do
      printf "withTestService: shutting down gRPC test server.\n"
      Async.cancel thread

-- | TODO
withTestClient :: (IO GRPC.Client -> TestTree) -> TestTree
withTestClient k =
  Test.Config.withTestConfig do
    config <- Test.Config.askConfigClientGRPC
    pure $ withTestGRPC \initGRPC ->
      withResource (onInit initGRPC config) onDone k
  where
    onInit :: IO GRPC -> GRPC.ClientConfig -> IO GRPC.Client
    onInit initGRPC config = do
      printf "withTestGRPC: initializing gRPC-haskell client.\n"
      grpc <- initGRPC
      GRPC.createClient grpc config

    onDone :: GRPC.Client -> IO ()
    onDone client = do
      printf "withTestGRPC: shutting down gRPC-haskell client.\n"
      GRPC.destroyClient client

-- | Creates an IO action that initializes gRPC core on a seperate thread and
-- passes that action, which returns the 'Async' handling the gRPC server, to
-- the continuation function.
--
-- The gRPC server will only start when the IO action is evaluated.
--
-- Shutdown of the gRPC server is handled when the continuation function is
-- completed or an exception is raised, either by gRPC-haskell-core or the
-- continuation.
withTestGRPC :: (IO GRPC -> TestTree) -> TestTree
withTestGRPC = withResource onInit onDone
  where
    onInit :: IO GRPC
    onInit = do
      printf "withTestGRPC: initializing gRPC-haskell-core.\n"
      GRPC.startGRPC

    onDone :: GRPC -> IO ()
    onDone grpc = do
      printf "withTestGRPC: shutting down gRPC-haskell-core.\n"
      GRPC.stopGRPC grpc
