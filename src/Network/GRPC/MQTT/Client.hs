{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Client
  ( MQTTGRPCClient (..),
    mqttRequest,
    withMQTTGRPCClient,
    connectMQTTGRPC,
    disconnectMQTTGRPC,
  )
where

import Relude

import Proto.Mqtt
  ( AuxControl (AuxControlAlive, AuxControlTerminate),
    AuxControlMessage (AuxControlMessage),
    RemoteError,
  )

import Control.Exception (bracket, throw)
import Control.Monad.Except (withExceptT)
import Crypto.Nonce (Generator, new, nonce128urlT)
import Network.GRPC.HighLevel
  ( GRPCIOError (GRPCIOTimeout),
    MethodName (MethodName),
  )
import Network.GRPC.HighLevel.Client
  ( ClientError (ClientIOError),
    ClientResult (ClientErrorResponse),
    TimeoutSeconds,
  )
import qualified Network.GRPC.HighLevel.Generated as HL
import Network.GRPC.HighLevel.Server (toBS)
import Network.GRPC.MQTT.Core
  ( MQTTGRPCConfig (_msgCB),
    connectMQTT,
    heartbeatPeriodSeconds,
    mqttMsgSizeLimit,
    subscribeOrThrow,
  )
import Network.GRPC.MQTT.Logging (Logger, logDebug, logErr)
import Network.GRPC.MQTT.Sequenced (mkPacketizedPublish, mkPacketizedRead)
import Network.GRPC.MQTT.Types
  ( MQTTRequest (MQTTNormalRequest, MQTTReaderRequest, MQTTWriterRequest),
    MQTTResult (GRPCResult, MQTTError),
  )
import Network.GRPC.MQTT.Wrapping
import Network.MQTT.Client
  ( MQTTClient,
    MQTTException (MQTTException),
    MessageCallback (SimpleCallback),
    normalDisconnect,
  )
import Network.MQTT.Topic (Topic (unTopic), mkTopic, toFilter)
import qualified Proto.Mqtt as Proto
import Proto3.Suite
  ( Enumerated (Enumerated),
    HasDefault,
    Message,
    def,
    toLazyByteString,
  )
import Turtle (sleep)
import UnliftIO (MonadUnliftIO)
import UnliftIO.Async (withAsync)
import UnliftIO.Exception (handle, onException)
import UnliftIO.STM
  ( TChan,
    newTChanIO,
    writeTChan,
  )
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
  , -- | Maximum size for an MQTT message in bytes
    msgSizeLimit :: Int64
  }

{- | Connects to the MQTT broker using the supplied 'MQTTConfig' and passes the `MQTTGRPCClient' to the supplied function, closing the connection for you when the function finishes.
 Disconnects from the MQTT broker with 'normalDisconnect' when finished.
-}
withMQTTGRPCClient :: Logger -> MQTTGRPCConfig -> (MQTTGRPCClient -> IO a) -> IO a
withMQTTGRPCClient logger cfg =
  bracket
    (connectMQTTGRPC logger cfg)
    disconnectMQTTGRPC

{- | Send a gRPC request over MQTT using the provided client
 This function makes synchronous requests.
-}
mqttRequest ::
  forall request response streamtype.
  (Message request, Message response, HasDefault request) =>
  MQTTGRPCClient ->
  Topic ->
  MethodName ->
  MQTTRequest streamtype request response ->
  IO (MQTTResult streamtype response)
mqttRequest MQTTGRPCClient{..} baseTopic (MethodName method) request = do
  logDebug mqttLogger $ "Making gRPC request for method: " <> decodeUtf8 method

  handle handleMQTTException $ do
    sessionId <- generateSessionId rng
    let responseTopic = baseTopic <> "grpc" <> "session" <> sessionId
    let controlTopic = responseTopic <> "control"
    let baseRequestTopic = baseTopic <> "grpc" <> "request" <> sessionId

    requestTopic <-
      mkTopic (unTopic baseRequestTopic <> decodeUtf8 method)
        `whenNothing` throw (MQTTException $ "gRPC method forms invalid topic: " <> decodeUtf8 method)

    publishReq' <- mkPacketizedPublish mqttClient msgSizeLimit requestTopic
    let publishToRequestTopic :: forall r. Message r => r -> IO ()
        publishToRequestTopic = publishReq' . toLazyByteString

    let publishRequest :: request -> TimeoutSeconds -> HL.MetadataMap -> IO ()
        publishRequest req timeLimit reqMetadata = do
          logDebug mqttLogger $ "Publishing message to topic: " <> unTopic requestTopic
          let protoRequest =
                Proto.MQTTRequest
                  (fromIntegral timeLimit)
                  (Just $ fromMetadataMap reqMetadata)
                  (toBS req)
          publishToRequestTopic protoRequest

    publishCtrl' <- mkPacketizedPublish mqttClient msgSizeLimit controlTopic
    let publishToControlTopic :: forall r. Message r => r -> IO ()
        publishToControlTopic = publishCtrl' . toLazyByteString

    let publishControlMsg :: AuxControl -> IO ()
        publishControlMsg ctrl = do
          let ctrlMessage = AuxControlMessage (Enumerated (Right ctrl))
          logDebug mqttLogger $ "Publishing control message " <> show ctrl <> " to topic: " <> unTopic controlTopic
          publishToControlTopic ctrlMessage

    readResponseTopic <- mkPacketizedRead responseChan

    -- Subscribe to response topic
    subscribeOrThrow mqttClient [toFilter responseTopic]

    -- Process request
    case request of
      -- Unary Requests
      MQTTNormalRequest req timeLimit reqMetadata ->
        grpcTimeout timeLimit $ do
          publishRequest req timeLimit reqMetadata
          withControlSignals publishControlMsg . exceptToResult $ do
            rsp <- readResponseTopic
            hoistEither $ unwrapUnaryResponse rsp

      -- Client Streaming Requests
      MQTTWriterRequest timeLimit initMetadata streamHandler -> do
        let publishStream :: request -> IO (Either GRPCIOError ())
            publishStream req = do
              logDebug mqttLogger $ "Publishing stream chunk to topic: " <> unTopic requestTopic
              let wrappedReq = wrapStreamChunk (Just req)
              publishToRequestTopic wrappedReq
              -- TODO: Fix this. Send errors won't be propagated to client's send handler
              return $ Right ()

        grpcTimeout timeLimit $ do
          -- send initMetadata
          publishRequest def timeLimit initMetadata
          withControlSignals publishControlMsg . exceptToResult $ do
            liftIO $ do
              -- do client streaming
              streamHandler publishStream
              -- Publish 'Nothing' to denote end of stream
              publishToRequestTopic $ wrapStreamChunk @request Nothing

            rsp <- readResponseTopic
            hoistEither $ unwrapClientStreamResponse rsp

      -- Server Streaming Requests
      MQTTReaderRequest req timeLimit reqMetadata streamHandler ->
        grpcTimeout timeLimit $ do
          publishRequest req timeLimit reqMetadata

          withControlSignals publishControlMsg . exceptToResult $ do
            -- Wait for initial metadata
            rawInitMetadata <- readResponseTopic
            metadata <- hoistEither $ parseMessageOrError rawInitMetadata

            let mqttSRecv :: IO (Either GRPCIOError (Maybe response))
                mqttSRecv = runExceptT . withExceptT toGRPCIOError $ do
                  rsp <- readResponseTopic
                  hoistEither $ unwrapStreamChunk @response rsp

            -- Run user-provided stream handler
            liftIO $ streamHandler (toMetadataMap metadata) mqttSRecv

            -- Return final result
            rsp <- readResponseTopic
            hoistEither $ unwrapServerStreamResponse rsp
  where
    handleMQTTException :: MQTTException -> IO (MQTTResult streamtype response)
    handleMQTTException e = do
      let errMsg = toText $ displayException e
      logErr mqttLogger errMsg
      return $ MQTTError errMsg

{- | Helper function to run an 'ExceptT RemoteError' action and convert any failure
 to an 'MQTTResult'
-}
exceptToResult :: (Functor m) => ExceptT RemoteError m (MQTTResult streamtype response) -> m (MQTTResult streamtype response)
exceptToResult = fmap (either fromRemoteError id) . runExceptT

{- | Manages the control signals (Heartbeat and Terminate) asynchronously while
 the provided action performs a request
-}
withControlSignals :: (AuxControl -> IO ()) -> IO a -> IO a
withControlSignals publishControlMsg = withMQTTHeartbeat . sendTerminateOnException
  where
    withMQTTHeartbeat :: IO a -> IO a
    withMQTTHeartbeat action =
      withAsync
        (forever (publishControlMsg AuxControlAlive >> sleep heartbeatPeriodSeconds))
        (const action)

    sendTerminateOnException :: IO a -> IO a
    sendTerminateOnException action =
      action `onException` publishControlMsg AuxControlTerminate

{- | Connects to the MQTT broker and creates a 'MQTTGRPCClient'
 NB: Overwrites the '_msgCB' field in the 'MQTTConfig'
-}
connectMQTTGRPC :: (MonadIO io) => Logger -> MQTTGRPCConfig -> io MQTTGRPCClient
connectMQTTGRPC logger cfg = do
  resultChan <- newTChanIO

  let clientMQTTHandler :: MessageCallback
      clientMQTTHandler =
        SimpleCallback $ \_client topic mqttMessage _props -> do
          logDebug logger $ "clientMQTTHandler received message on topic: " <> unTopic topic <> " Raw: " <> decodeUtf8 mqttMessage
          atomically $ writeTChan resultChan mqttMessage

  MQTTGRPCClient
    <$> connectMQTT cfg{_msgCB = clientMQTTHandler}
    <*> pure resultChan
    <*> new
    <*> pure logger
    <*> pure (fromIntegral (mqttMsgSizeLimit cfg))

disconnectMQTTGRPC :: (MonadIO io) => MQTTGRPCClient -> io ()
disconnectMQTTGRPC = liftIO . normalDisconnect . mqttClient

-- | Returns a 'GRPCIOTimeout' error if the supplied function takes longer than the given timeout.
grpcTimeout :: (MonadUnliftIO m) => TimeoutSeconds -> m (MQTTResult streamType response) -> m (MQTTResult streamType response)
grpcTimeout timeLimit action = fromMaybe timeoutError <$> timeout (timeLimit * 1000000) action
  where
    timeoutError = GRPCResult $ ClientErrorResponse (ClientIOError GRPCIOTimeout)

-- | Generate a new random 'SessionId' and parse it into a 'Topic'
generateSessionId :: Generator -> IO Topic
generateSessionId randGen =
  mkTopic <$> nonce128urlT randGen >>= \case
    Just topic -> pure topic
    Nothing -> throw $ MQTTException "Failed to generate a valid session ID. (This should be impossible)"
