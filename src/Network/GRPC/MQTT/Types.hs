-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE ImplicitPrelude #-}

-- |
module Network.GRPC.MQTT.Types
  ( MQTTResult (..),
    MethodMap,
    ClientHandler (..),
    MQTTRequest (..),
    SessionId,
    Batched (..),
  )
where

--------------------------------------------------------------------------------

import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Text (Text)
import Data.HashMap.Strict (HashMap)
import Data.List (intercalate)

import Language.Haskell.TH.Syntax (Lift)

import Network.GRPC.HighLevel.Client
  ( ClientResult,
    GRPCMethodType (BiDiStreaming, ClientStreaming, Normal, ServerStreaming),
    MetadataMap,
    StreamRecv,
    StreamSend,
    TimeoutSeconds,
    WritesDone,
  )
import Network.GRPC.LowLevel (ClientCall)

import Proto3.Suite (Message)

--------------------------------------------------------------------------------

-- | Represents the session ID for a request
type SessionId = Text

-- | Analogous of 'ClientRequest' from grpc-haskell with the unused fields removed
data MQTTRequest :: GRPCMethodType -> Type -> Type -> Type where
  MQTTNormalRequest ::
    rqt ->
    TimeoutSeconds ->
    MetadataMap ->
    MQTTRequest 'Normal rqt rsp
  MQTTWriterRequest ::
    TimeoutSeconds ->
    MetadataMap ->
    (StreamSend rqt -> IO ()) ->
    MQTTRequest 'ClientStreaming rqt rsp
  MQTTReaderRequest ::
    rqt ->
    TimeoutSeconds ->
    MetadataMap ->
    (MetadataMap -> StreamRecv rsp -> IO ()) ->
    MQTTRequest 'ServerStreaming rqt rsp
  MQTTBiDiRequest ::
    TimeoutSeconds ->
    MetadataMap ->
    (MetadataMap -> StreamRecv rsp -> StreamSend rqt -> WritesDone -> IO ()) ->
    MQTTRequest 'BiDiStreaming rqt rsp

-- | @since 1.0.0
instance Show rqt => Show (MQTTRequest s rqt rsp) where
  show (MQTTNormalRequest x timeout metadata) =
    intercalate " " [show 'MQTTNormalRequest, show x, show timeout, show metadata]
  show (MQTTWriterRequest timeout metadata _) =
    intercalate " " [show 'MQTTWriterRequest, show timeout, show metadata]
  show (MQTTReaderRequest x timeout metadata _) =
    intercalate " " [show 'MQTTReaderRequest, show x, show timeout, show metadata]
  show (MQTTBiDiRequest timeout metadata _) =
    intercalate " " [show 'MQTTBiDiRequest, show timeout, show metadata]
  {-# INLINE show #-}

--------------------------------------------------------------------------------

-- | The result of a gRPC request that makes a distinction between
-- errors that occured as part of the GRPC call itself, or in the MQTT handling.
data MQTTResult streamtype response
  = MQTTError Text
  | GRPCResult (ClientResult streamtype response)

--------------------------------------------------------------------------------

-- | A map from gRPC method names to their corresponding handler
type MethodMap = HashMap ByteString ClientHandler

-- | Client gRPC handlers used by the remote gRPC client to make requests
data ClientHandler where
  ClientUnaryHandler ::
    (Message response) =>
    (ByteString -> TimeoutSeconds -> MetadataMap -> IO (ClientResult 'Normal response)) ->
    ClientHandler
  ClientClientStreamHandler ::
    (Message request, Message response) =>
    (TimeoutSeconds -> MetadataMap -> (StreamSend request -> IO ()) -> IO (ClientResult 'ClientStreaming response)) ->
    ClientHandler
  ClientServerStreamHandler ::
    (Message response) =>
    Batched ->
    (ByteString -> TimeoutSeconds -> MetadataMap -> (ClientCall -> MetadataMap -> StreamRecv response -> IO ()) -> IO (ClientResult 'ServerStreaming response)) ->
    ClientHandler
  ClientBiDiStreamHandler ::
    (Message request, Message response) =>
    Batched ->
    (TimeoutSeconds -> MetadataMap -> (ClientCall -> MetadataMap -> StreamRecv response -> StreamSend request -> WritesDone -> IO ()) -> IO (ClientResult 'BiDiStreaming response)) ->
    ClientHandler

-- | Indicates whether streaming messages are batched.
--
-- Batched streaming packs as many messages as possible to a single
-- packet published over MQTT. The maximum size of a packet is defined
-- by @MQTTGRPCConfig.mqttMsgSizeLimit@. The sender will accumulate
-- multiple messages in memory till it reaches the packet size limit and
-- then all the messages are sent in one packet.
--
-- Batching helps to improve performance when many small messages are
-- streamed in a short time. On the other hand, it is not a good idea to
-- batch RPCs that send small messages infrequently (long-poll) because
-- messages will not be published immediately.
data Batched = Unbatched | Batched
  deriving (Eq, Ord, Lift)
