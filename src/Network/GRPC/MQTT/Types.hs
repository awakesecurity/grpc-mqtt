{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Network.GRPC.MQTT.Types (
  MQTTResult (..),
  MethodMap,
  SomeClientHandler (..),
  ClientHandler (..),
  MQTTRequest (..),
) where

import Relude

import qualified Network.GRPC.HighLevel as HL
import Network.GRPC.HighLevel.Client (
  ClientResult,
  GRPCMethodType (..),
  MetadataMap,
  StreamRecv,
  TimeoutSeconds,
 )
import Network.GRPC.LowLevel (ClientCall)
import Proto3.Suite (Message)

-- | Analogs of 'GRPCRequest' with the unused fields removed
data MQTTRequest (streamType :: GRPCMethodType) request response where
  MQTTNormalRequest :: request -> TimeoutSeconds -> HL.MetadataMap -> MQTTRequest 'Normal request response
  MQTTReaderRequest :: request -> TimeoutSeconds -> HL.MetadataMap -> (HL.MetadataMap -> StreamRecv response -> IO ()) -> MQTTRequest 'ServerStreaming request response

{- | The result of a gRPC request that makes a distinction between
 errors that occured as part of the GRPC call itself, or in the MQTT handling.
-}
data MQTTResult streamtype response
  = MQTTError Text
  | GRPCResult (ClientResult streamtype response)

-- | A map from gRPC method names to their corresponding handler
type MethodMap = HashMap ByteString SomeClientHandler

-- | Existential wrapper for 'ClientHandler'
data SomeClientHandler = forall (a :: GRPCMethodType). SomeClientHandler (ClientHandler a)

-- | Client gRPC handlers used by the remote gRPC client to make requests
data ClientHandler (a :: GRPCMethodType) where
  ClientUnaryHandler ::
    (Message response) =>
    (ByteString -> TimeoutSeconds -> MetadataMap -> IO (ClientResult 'Normal response)) ->
    ClientHandler 'Normal
  ClientServerStreamHandler ::
    (Message response) =>
    (ByteString -> TimeoutSeconds -> MetadataMap -> (ClientCall -> MetadataMap -> StreamRecv response -> IO ()) -> IO (ClientResult 'ServerStreaming response)) ->
    ClientHandler 'ServerStreaming
