{- 
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}

{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Client (
  MQTTGRPCClient (..),
  mqttRequest,
  withMQTTGRPCClient,
  connectMQTTGRPC,
) where

import Relude

import Proto.Mqtt (
  AuxControl (AuxControlAlive, AuxControlTerminate),
  AuxControlMessage (AuxControlMessage),
  RemoteClientError,
 )

import Network.GRPC.MQTT.Core (MQTTConnectionConfig, connectMQTT, heartbeatPeriodSeconds, setCallback, Logger, logErr, logDebug)
import Network.GRPC.MQTT.Sequenced (mkSequencedRead)
import Network.GRPC.MQTT.Types (
  MQTTRequest (MQTTNormalRequest, MQTTReaderRequest),
  MQTTResult (GRPCResult, MQTTError),
 )
import Network.GRPC.MQTT.Wrapping (
  fromRemoteClientError,
  parseErrorToRCE,
  toMetadataMap,
  unwrapSequencedResponse,
  unwrapStreamChunk,
  unwrapStreamResponse,
  unwrapUnaryResponse,
  wrapRequest,
 )

import Control.Exception (bracket)
import Crypto.Nonce (Generator, new, nonce128urlT)
import Network.GRPC.HighLevel (
  GRPCIOError (GRPCIOTimeout),
  MethodName (MethodName),
 )
import Network.GRPC.HighLevel.Client (
  ClientError (ClientIOError),
  ClientResult (ClientErrorResponse),
  TimeoutSeconds,
 )
import Network.GRPC.HighLevel.Generated as HL (
  MetadataMap,
 )
import Network.MQTT.Client (
  MQTTClient,
  MessageCallback (SimpleCallback),
  QoS (QoS1),
  SubOptions (_subQoS),
  Topic,
  normalDisconnect,
  publishq,
  subOptions,
  subscribe,
 )
import Proto3.Suite (
  Enumerated (Enumerated),
  Message,
  fromByteString,
  toLazyByteString,
 )
import Turtle (sleep)
import UnliftIO (MonadUnliftIO)
import UnliftIO.Async (withAsync)
import UnliftIO.Exception (onException)
import UnliftIO.STM (TChan, newTChanIO, readTChan, writeTChan)
import UnliftIO.Timeout (timeout)

-- | Client for making gRPC calls over MQTT
data MQTTGRPCClient = MQTTGRPCClient
  { -- | The MQTT client
    mqttClient :: MQTTClient
  , -- | Channel for passing MQTT messages back to calling thread
    responseChan :: TChan LByteString
  , -- | Random number generator for generating session IDs
    rng :: Generator
  , -- | Logging 
    mqttLogger :: Logger
  }

{- | Connects to the MQTT broker using the supplied 'MQTTConfig' and passes the `MQTTGRPCClient' to the supplied function, closing the connection for you when the function finishes.
 Disconnects from the MQTT broker with 'normalDisconnect' when finished.
-}
withMQTTGRPCClient :: Logger -> MQTTConnectionConfig -> (MQTTGRPCClient -> IO a) -> IO a
withMQTTGRPCClient logger cfg =
  bracket
    (connectMQTTGRPC logger cfg)
    (normalDisconnect . mqttClient)

{- | Send a gRPC request over MQTT using the provided client
 This function makes synchronous requests.
-}
mqttRequest ::
  forall request response streamtype.
  (Message request, Message response) =>
  MQTTGRPCClient ->
  Topic ->
  MethodName ->
  MQTTRequest streamtype request response ->
  IO (MQTTResult streamtype response)
mqttRequest MQTTGRPCClient{..} baseTopic (MethodName method) request = do
  logDebug mqttLogger $ "Making gRPC request for method: " <> decodeUtf8 method
  
  sessionID <- nonce128urlT rng
  let responseTopic = baseTopic <> "/grpc/session/" <> sessionID
  let requestTopic = baseTopic <> "/grpc/request" <> decodeUtf8 method
  let controlTopic = responseTopic <> "/control"

  let publishRequest :: request -> TimeoutSeconds -> HL.MetadataMap -> IO ()
      publishRequest req timeLimit reqMetadata = do
        logDebug mqttLogger $ "Publishing message to topic: " <> responseTopic
        let wrappedReq = wrapRequest responseTopic timeLimit reqMetadata req
        publishq mqttClient requestTopic wrappedReq False QoS1 []

  let publishControlMsg :: AuxControl -> IO ()
      publishControlMsg ctrl = publishq mqttClient controlTopic ctrlMessage False QoS1 []
       where
        ctrlMessage = toLazyByteString $ AuxControlMessage (Enumerated (Right ctrl))

  let sendTerminateOnException :: IO a -> IO a
      sendTerminateOnException action = onException action $ do
        logErr mqttLogger "Exception while waiting for response"
        publishControlMsg AuxControlTerminate

  -- Subscribe to response topic
  (subResults, _) <- subscribe mqttClient [(responseTopic, subOptions{_subQoS = QoS1})] []
  case subResults of
    [Left subErr] -> do
      let errMsg = "Failed to subscribe to the topic: " <> responseTopic <> "Reason: " <> show subErr
      logErr mqttLogger errMsg
      return $ MQTTError errMsg
        
    _ -> do
      -- Process request
      case request of
        -- Unary Requests
        MQTTNormalRequest req timeLimit reqMetadata ->
          grpcTimeout timeLimit $ do
            publishRequest req timeLimit reqMetadata
            sendTerminateOnException $
              unwrapUnaryResponse <$> atomically (readTChan responseChan)

        -- Server Streaming Requests
        MQTTReaderRequest req timeLimit reqMetadata streamHandler ->
          grpcTimeout timeLimit $ do
            publishRequest req timeLimit reqMetadata

            let withMQTTHeartbeat :: IO a -> IO a
                withMQTTHeartbeat action =
                  withAsync
                    (forever (publishControlMsg AuxControlAlive >> sleep heartbeatPeriodSeconds))
                    (const action)

            withMQTTHeartbeat . sendTerminateOnException $ do
              let readUnwrapped = unwrapSequencedResponse . toStrict <$> readTChan responseChan
              orderedRead <- mkSequencedRead readUnwrapped

              let readInitMetadata :: IO (Either RemoteClientError HL.MetadataMap)
                  readInitMetadata = do
                    rawInitMD <- orderedRead
                    let parsedMD = first parseErrorToRCE . fromByteString =<< rawInitMD
                    return $ fmap toMetadataMap parsedMD

              -- Wait for initial metadata
              readInitMetadata >>= \case
                Left err -> pure $ fromRemoteClientError err
                Right metadata -> do
                  -- Adapter to recieve stream from MQTT
                  let mqttSRecv = unwrapStreamChunk <$> orderedRead

                  -- Run user-provided stream handler
                  streamHandler metadata mqttSRecv

                  -- Return final result
                  unwrapStreamResponse <$> atomically (readTChan responseChan)

{- | Connects to the MQTT broker and creates a 'MQTTGRPCClient'
 NB: Overwrites the '_msgCB' field in the 'MQTTConfig'
-}
connectMQTTGRPC :: (MonadIO m) => Logger -> MQTTConnectionConfig -> m MQTTGRPCClient
connectMQTTGRPC logger cfg = do
  resultChan <- newTChanIO

  let clientMQTTHandler :: MessageCallback
      clientMQTTHandler =
        SimpleCallback $ \_client topic mqttMessage _props -> do
          logDebug logger $ "clientMQTTHandler received message on topic: " <> topic
          atomically $ writeTChan resultChan mqttMessage

  MQTTGRPCClient
    <$> connectMQTT (cfg & setCallback clientMQTTHandler)
    <*> pure resultChan
    <*> new
    <*> pure logger

-- | Returns a 'GRPCIOTimeout' error if the supplied function takes longer than the given timeout.
grpcTimeout :: (MonadUnliftIO m) => TimeoutSeconds -> m (MQTTResult streamType response) -> m (MQTTResult streamType response)
grpcTimeout timeLimit action = fromMaybe timeoutError <$> timeout (timeLimit * 1000000) action
 where
  timeoutError = GRPCResult $ ClientErrorResponse (ClientIOError GRPCIOTimeout)
