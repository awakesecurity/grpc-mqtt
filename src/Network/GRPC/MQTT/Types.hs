{- 
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}

{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Network.GRPC.MQTT.Types (
  MQTTResult (..),
  MethodMap,
  ClientHandler (..),
  MQTTRequest (..),
SessionId) where

import Relude

import qualified Network.GRPC.HighLevel as HL
import Network.GRPC.HighLevel.Client (
  ClientResult,
  GRPCMethodType (Normal, ServerStreaming, ClientStreaming),
  MetadataMap,
  StreamRecv,
  TimeoutSeconds, StreamSend
 )
import Network.GRPC.LowLevel (ClientCall)
import Proto3.Suite (Message)

-- | Represents the session ID for a request
type SessionId = Text

-- | Analogs of 'ClientRequest' from grpc-haskell with the unused fields removed
data MQTTRequest (streamType :: GRPCMethodType) request response where
  MQTTNormalRequest :: request -> TimeoutSeconds -> HL.MetadataMap -> MQTTRequest 'Normal request response
  MQTTWriterRequest :: TimeoutSeconds -> HL.MetadataMap -> (StreamSend request -> IO ()) -> MQTTRequest 'ClientStreaming request response
  MQTTReaderRequest :: request -> TimeoutSeconds -> HL.MetadataMap -> (HL.MetadataMap -> StreamRecv response -> IO ()) -> MQTTRequest 'ServerStreaming request response

{- | The result of a gRPC request that makes a distinction between
 errors that occured as part of the GRPC call itself, or in the MQTT handling.
-}
data MQTTResult streamtype response
  = MQTTError Text
  | GRPCResult (ClientResult streamtype response)

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
    (ByteString -> TimeoutSeconds -> MetadataMap -> (ClientCall -> MetadataMap -> StreamRecv response -> IO ()) -> IO (ClientResult 'ServerStreaming response)) ->
    ClientHandler
