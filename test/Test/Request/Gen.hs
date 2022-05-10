{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | TODO
--
-- @since 1.0.0
module Test.Request.Gen
  ( -- * TODO
    normalRequest,
    clientStreamRequest,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (MonadGen, Range)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

--------------------------------------------------------------------------------

import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue (TQueue, writeTQueue)

import Control.Monad.IO.Class (MonadIO, liftIO)

import Data.Foldable (traverse_)
import Data.Function (fix)

import Data.Either (lefts)
import Data.IORef (IORef, atomicWriteIORef, modifyIORef')
import Data.Text.Lazy qualified as Lazy.Text

import Network.GRPC.HighLevel (GRPCIOError)
import Network.GRPC.HighLevel.Client (GRPCMethodType)
import Network.GRPC.HighLevel.Client qualified as GRPC.Client
import Network.GRPC.HighLevel.Server (ServerRequest, ServerResponse)
import Network.GRPC.HighLevel.Server qualified as GRPC.Server

import Network.GRPC.MQTT.Types (MQTTRequest)
import Network.GRPC.MQTT.Types qualified as GRPC.MQTT

--------------------------------------------------------------------------------

import Test.Network.GRPC.HighLevel.Extra.Gen qualified as Gen

--------------------------------------------------------------------------------

import Proto.Message (BiDiRequestReply, StreamRequest, StreamReply)
import Proto.Message qualified as Message

--------------------------------------------------------------------------------

-- | TODO
normalRequest ::
  MonadGen m =>
  rqt ->
  m (MQTTRequest 'GRPC.Client.Normal rqt rsp)
normalRequest body = do
  metadata <- Gen.metadataMap
  pure (GRPC.MQTT.MQTTNormalRequest body 5 metadata)

-- | TODO
clientStreamRequest ::
  forall m rqt rsp.
  MonadGen m =>
  [rqt] ->
  m (MQTTRequest 'GRPC.Client.ClientStreaming rqt rsp)
clientStreamRequest rqts = do
  metadata <- Gen.metadataMap
  pure (GRPC.MQTT.MQTTWriterRequest 5 metadata clientStreamHandler)
  where
    clientStreamHandler :: GRPC.Client.StreamSend rqt -> IO ()
    clientStreamHandler send = traverse_ send rqts
