{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Client (
  MQTTGRPCClient,
  mqttRequest,
  withMQTTGRPCClient,
  connectMQTTGRPC,
) where

import Relude

import Proto.Mqtt

import Network.GRPC.MQTT.Core
import Network.GRPC.MQTT.Wrapping

import Control.Exception (bracket)
import Crypto.Nonce
import Network.GRPC.HighLevel
import Network.GRPC.HighLevel.Client
import Network.GRPC.HighLevel.Generated as HL
import Network.GRPC.MQTT.Sequenced (mkSequencedRead)
import Network.GRPC.MQTT.Types
import Network.MQTT.Client
import Proto3.Suite
import UnliftIO (MonadUnliftIO)
import UnliftIO.Async (withAsync)
import UnliftIO.Concurrent (threadDelay)
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
  }

{- | Connects to the MQTT broker using the supplied 'MQTTConfig' and pass the `MQTTGRPCClient' to the supplied function.
 Disconnects from the MQTT broker with 'normalDisconnect' when finished.
-}
withMQTTGRPCClient :: MQTTConfig -> (MQTTGRPCClient -> IO a) -> IO a
withMQTTGRPCClient cfg =
  bracket
    (connectMQTTGRPC cfg)
    (normalDisconnect . mqttClient)

{- | Send a gRPC request over MQTT using the provided client
 This function makes syncronous requests.
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
  sessionID <- nonce128urlT rng
  let responseTopic = baseTopic <> "/grpc/session/" <> sessionID
  let requestTopic = baseTopic <> "/grpc/request" <> decodeUtf8 method
  let controlTopic = responseTopic <> "/control"

  let publishRequest :: request -> TimeoutSeconds -> HL.MetadataMap -> IO ()
      publishRequest req timeLimit reqMetadata = do
        let wrappedReq = wrapRequest responseTopic timeLimit reqMetadata req
        publishq mqttClient requestTopic wrappedReq False QoS1 []

  let publishControlMsg :: AuxControl -> IO ()
      publishControlMsg ctrl = publishq mqttClient controlTopic ctrlMessage False QoS1 []
       where
        ctrlMessage = toLazyByteString $ AuxControlMessage (Enumerated (Right ctrl))

  let sendTerminateOnException :: IO a -> IO a
      sendTerminateOnException action = action `onException` publishControlMsg AuxControlTerminate

  -- Subscribe to response topic
  _ <- subscribe mqttClient [(responseTopic, subOptions{_subQoS = QoS1})] []

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
                (forever (publishControlMsg AuxControlAlive >> threadDelay (heartbeatPeriod*1000000)))
                (const action)

        withMQTTHeartbeat . sendTerminateOnException $ do
          orderedRead <- mkSequencedRead $ unwrapSequencedResponse . toStrict <$> readTChan responseChan

          let readInitMetadata :: IO (Either RemoteClientError HL.MetadataMap)
              readInitMetadata = do
                rawInitMD <- orderedRead
                let parsedMD = first parseErrorToRCE . fromByteString =<< rawInitMD
                return $ fmap toMetadataMap parsedMD

          -- Wait for initial metadata
          mInitMD <- readInitMetadata
          case mInitMD of
            Left err -> pure $ fromRemoteClientError err
            Right metadata -> do
              -- Adaptor to recieve stream from MQTT
              let mqttSRecv = unwrapStreamChunk <$> orderedRead

              -- Run user-provided stream handler
              streamHandler metadata mqttSRecv

              -- Return final result
              unwrapStreamResponse <$> atomically (readTChan responseChan)

-- | Connects to the MQTT broker and creates a 'MQTTGRPCClient'
-- NB: Overwrites the '_msgCB' field in the 'MQTTConfig'
connectMQTTGRPC :: (MonadIO m) => MQTTConfig -> m MQTTGRPCClient
connectMQTTGRPC cfg = do
  resultChan <- newTChanIO

  let clientMQTTHandler :: MessageCallback
      clientMQTTHandler =
        SimpleCallback $ \_client _topic mqttMessage _props -> do
          atomically $ writeTChan resultChan mqttMessage

  MQTTGRPCClient 
    <$> connectMQTT cfg{_msgCB = clientMQTTHandler}
    <*> pure resultChan
    <*> new

-- | Returns a 'GRPCIOTimeout' error if the supplied function takes longer than the given timeout.
grpcTimeout :: (MonadUnliftIO m) => TimeoutSeconds -> m (MQTTResult streamType response) -> m (MQTTResult streamType response)
grpcTimeout timeLimit action = fromMaybe timeoutError <$> timeout (timeLimit * 1000000) action
 where
  timeoutError = GRPCResult $ ClientErrorResponse (ClientIOError GRPCIOTimeout)
