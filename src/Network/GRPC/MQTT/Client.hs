-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE RecordWildCards #-}

-- |
module Network.GRPC.MQTT.Client
  ( MQTTGRPCClient (..),
    mqttRequest,
    withMQTTGRPCClient,
    connectMQTTGRPC,
    disconnectMQTTGRPC,
  )
where

import Proto.Mqtt
  ( AuxControl (AuxControlAlive, AuxControlTerminate),
    AuxControlMessage (AuxControlMessage),
    RemoteError,
  )

import Control.Exception (bracket, throw)
import Control.Monad.Except (ExceptT (ExceptT), throwError, withExceptT)
import Crypto.Nonce (Generator, new, nonce128urlT)
import Network.GRPC.HighLevel
  ( GRPCIOError (GRPCIOTimeout),
    MethodName (MethodName),
    StreamRecv,
    StreamSend,
  )
import Network.GRPC.HighLevel.Client
  ( ClientError (ClientIOError),
    ClientResult (ClientErrorResponse),
    TimeoutSeconds,
    WritesDone,
  )
import Network.GRPC.HighLevel.Generated qualified as HL
import Network.GRPC.HighLevel.Client
import Network.GRPC.HighLevel.Server (toBS)
import Proto3.Wire.Encode qualified as Wire.Encode
import Proto3.Wire.Decode qualified as Wire.Decode
import Proto3.Suite
  ( Enumerated (Enumerated),
    HasDefault,
    Message,
    def,
    toLazyByteString,
    fromByteString,
    encodeMessage,
  )
import Turtle (sleep)
import UnliftIO (MonadUnliftIO)
import UnliftIO.Async (withAsync)
import UnliftIO.Exception (handle, onException)
import UnliftIO.STM
  ( TChan
  , newTChanIO
  , tryReadTChan
  , readTChan
  , writeTChan
  )
import UnliftIO.Timeout (timeout)

import Network.GRPC.MQTT.Wrap
  ( WrapT (getWrapT, unwrapT),
    Wrap,
    fromEitherT,
    unwrap,
    pattern WrapEither,
    pattern WrapRight,
    pattern WrapError,
    readMetadataMap,
  )
import Network.GRPC.MQTT.Core
  ( Config (_msgCB),
    connectMQTT,
    heartbeatPeriodSeconds,
    mqttMsgSizeLimit,
    subscribeOrThrow,
  )

import Network.GRPC.MQTT.Response.BiDiStreaming qualified as Response.BiDiStreaming
import Network.GRPC.MQTT.Response.ClientStreaming qualified as Response.ClientStreaming
import Network.GRPC.MQTT.Response.Normal qualified as Response.Normal
import Network.GRPC.MQTT.Response.ServerStreaming qualified as Response.ServerStreaming

import Network.GRPC.MQTT.Request (Request (Request))
import Network.GRPC.MQTT.Request qualified as Request

import Network.GRPC.MQTT.Logging (Logger, logDebug, logErr)
import Network.GRPC.MQTT.Sequenced
import Network.GRPC.MQTT.Types
  ( Batched,
    MQTTRequest (MQTTBiDiRequest, MQTTNormalRequest, MQTTReaderRequest, MQTTWriterRequest),
    MQTTResult (GRPCResult, MQTTError),
  )
import Network.GRPC.MQTT.Wrapping
  ( fromRemoteError,
    toGRPCIOError,
    unwrapBiDiStreamResponse,
    unwrapClientStreamResponse,
    unwrapServerStreamResponse,
    unwrapUnaryResponse,
    toStatusDetails,
    toStatusCode,
  )
import Network.MQTT.Client
  ( MQTTClient,
    MQTTException (MQTTException),
    MessageCallback (SimpleCallback),
    normalDisconnect,
  )
import Network.MQTT.Topic (Topic (unTopic), mkTopic, toFilter)

--------------------------------------------------------------------------------

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

-- | Connects to the MQTT broker using the supplied 'MQTTConfig' and passes the
-- `MQTTGRPCClient' to the supplied function, closing the connection for you
-- when the function finishes.
--
-- Disconnects from the MQTT broker with 'normalDisconnect' when finished.
withMQTTGRPCClient :: Logger -> Config -> (MQTTGRPCClient -> IO a) -> IO a
withMQTTGRPCClient logger cfg =
  bracket
    (connectMQTTGRPC logger cfg)
    disconnectMQTTGRPC

-- | Send a gRPC request over MQTT using the provided client
-- This function makes synchronous requests.
mqttRequest ::
  forall request response streamtype.
  (Message request, Message response, HasDefault request) =>
  MQTTGRPCClient ->
  Topic ->
  MethodName ->
  Batched ->
  MQTTRequest streamtype request response ->
  IO (MQTTResult streamtype response)
mqttRequest MQTTGRPCClient{..} baseTopic (MethodName method) useBatchedStream request = do
  logDebug mqttLogger $ "Making gRPC request for method: " <> decodeUtf8 method

  handle handleMQTTException $ do
    sessionId <- generateSessionId rng
    let responseTopic = baseTopic <> "grpc" <> "session" <> sessionId
    let controlTopic = responseTopic <> "control"
    let baseRequestTopic = baseTopic <> "grpc" <> "request" <> sessionId

    requestTopic <-
      mkTopic (unTopic baseRequestTopic <> decodeUtf8 method)
        `whenNothing` throw (MQTTException $ "gRPC method forms invalid topic: " <> decodeUtf8 method)

    publishReq' <- mkPacketizedPublish mqttClient (fromIntegral msgSizeLimit) requestTopic

    let publishToRequestTopic :: Message r => r -> IO ()
        publishToRequestTopic = publishReq' . toLazyByteString

    let publishRequest :: request -> TimeoutSeconds -> HL.MetadataMap -> IO ()
        publishRequest rqt timeLimit reqMetadata = do
          logDebug mqttLogger $ "Publishing message to topic: " <> unTopic requestTopic
          let protoRequest = Request (toStrict $ toLazyByteString rqt) (fromIntegral timeLimit) reqMetadata
          publishReq' (Wire.Encode.toLazyByteString (Request.wireWrapRequest protoRequest))

    publishCtrl' <- mkPacketizedPublish mqttClient (fromIntegral msgSizeLimit) controlTopic

    let publishToControlTopic :: Message r => r -> IO ()
        publishToControlTopic = publishCtrl' . toLazyByteString

    let publishControlMsg :: AuxControl -> IO ()
        publishControlMsg ctrl = do
          let ctrlMessage = AuxControlMessage (Enumerated (Right ctrl))
          logDebug mqttLogger $ "Publishing control message " <> show ctrl <> " to topic: " <> unTopic controlTopic
          publishToControlTopic ctrlMessage

    PublishToStream {..} <- publishStream (fromIntegral msgSizeLimit) useBatchedStream \chunk ->
          publishReq' (Wire.Encode.toLazyByteString (Request.wireWrapRequest (Request chunk maxBound mempty)))

    let publishToRequestStream :: request -> IO (Either GRPCIOError ())
        publishToRequestStream rqt = do
          logDebug mqttLogger $ "Publishing stream chunk to topic: " <> unTopic requestTopic
          publishToStream (toStrict $ toLazyByteString rqt)
          return $ Right ()

    readResponseTopic <- mkPacketizedRead responseChan

    -- Subscribe to response topic
    subscribeOrThrow mqttClient [toFilter responseTopic]

    -- Process request
    case request of
      -- Unary Requests
      MQTTNormalRequest msg timeLimit reqMetadata ->
        grpcTimeout timeLimit $ do
          let rqt = Request msg timeLimit reqMetadata
           in publishNormal mqttClient requestTopic (Wire.Encode.toLazyByteString (Request.wireEncodeRequest rqt))
          -- logDebug mqttLogger $ "Client: published request"
          withControlSignals publishControlMsg . exceptToResult $ do
            rspBytes <- liftIO do
              atomically (readTChan responseChan)

            case Wire.Decode.parse Response.Normal.wireDecodeNormalResponse (toStrict rspBytes) of
              Left err -> do
                print ("client error: " ++ show err)
                undefined
              Right rsp -> do
                pure (GRPCResult $ Response.Normal.toClientNormalResult rsp)

      -- Client Streaming Requests
      MQTTWriterRequest timeLimit initMetadata streamHandler -> do
        grpcTimeout timeLimit $ do
          -- publishRequest def timeLimit initMetadata
          let rqt = Request mempty timeLimit initMetadata
           in publishNormal mqttClient requestTopic (Wire.Encode.toLazyByteString (Request.wireWrapRequest rqt))
          withControlSignals publishControlMsg . exceptToResult $ do
            liftIO do
              streamHandler publishToRequestStream
              publishToStreamCompleted

            rspBytes <- liftIO do
              atomically (readTChan responseChan)

            case Wire.Decode.parse Response.ClientStreaming.wireDecodeClientStreamingResponse (toStrict rspBytes) of
              Left err -> do
                print ("client error: " ++ show err)
                undefined
              Right rsp -> do
                pure (GRPCResult $ Response.ClientStreaming.toClientStreamingResult rsp)

      -- Server Streaming Requests
      MQTTReaderRequest msg timeLimit metadata streamHandler ->
        grpcTimeout timeLimit $ do
          let rqt = Request msg timeLimit metadata
           in publishNormal mqttClient requestTopic (Wire.Encode.toLazyByteString (Request.wireEncodeRequest rqt))
          withControlSignals publishControlMsg . exceptToResult $ do
            -- Wait for initial metadata
            rawInitMetadata <- readResponseTopic

            metadata <- case readMetadataMap (fromLazy rawInitMetadata) of
              WrapError perr -> throwError perr
              WrapRight meta -> pure meta

            readResponseStream <- mkStreamRead readResponseTopic

            let mqttSRecv :: StreamRecv response
                mqttSRecv = runExceptT . withExceptT toGRPCIOError $ readResponseStream

             in -- Run user-provided stream handler
                liftIO $ streamHandler metadata mqttSRecv

            -- Return final result
            rspBytes <- readResponseTopic
            case Wire.Decode.parse Response.ServerStreaming.wireDecodeServerStreamingResponse (toStrict rspBytes) of
              Left err -> do
                print ("client error: " ++ show err)
                undefined
              Right rsp -> do
                pure (GRPCResult $ Response.ServerStreaming.toServerStreamingResult rsp)

      -- BiDirectional Server Streaming Requests
      MQTTBiDiRequest timeLimit reqMetadata streamHandler ->
        grpcTimeout timeLimit $ do
          publishRequest def timeLimit reqMetadata
          withControlSignals publishControlMsg . exceptToResult $ do
            -- Wait for initial metadata
            rawInitMetadata <- readResponseTopic

            metadata <- case readMetadataMap (fromLazy rawInitMetadata) of
              WrapError perr -> throwError perr
              WrapRight meta -> pure meta

            readResponseStream <- mkStreamRead readResponseTopic

            let mqttSRecv :: StreamRecv response
                mqttSRecv = runExceptT . withExceptT toGRPCIOError $ readResponseStream

            let mqttSSend :: StreamSend request
                mqttSSend = publishToRequestStream

            let mqttWritesDone :: WritesDone
                mqttWritesDone = do
                  publishToStreamCompleted
                  return $ Right ()

            -- Run user-provided stream handler
            liftIO $ streamHandler metadata mqttSRecv mqttSSend mqttWritesDone

            rspBytes <- readResponseTopic
            case Wire.Decode.parse Response.BiDiStreaming.wireDecodeBiDiStreamingResponse (toStrict rspBytes) of
              Left err -> do
                print ("client error: " ++ show err)
                undefined
              Right rsp -> do
                pure (GRPCResult $ Response.BiDiStreaming.toBiDiStreamingResult rsp)

  where
    handleMQTTException :: MQTTException -> IO (MQTTResult streamtype response)
    handleMQTTException e = do
      let errMsg = toText $ displayException e
      logErr mqttLogger errMsg
      return $ MQTTError errMsg

-- | Helper function to run an 'ExceptT RemoteError' action and convert any failure
-- to an 'MQTTResult'
exceptToResult :: (Functor m) => ExceptT RemoteError m (MQTTResult streamtype response) -> m (MQTTResult streamtype response)
exceptToResult = fmap (either fromRemoteError id) . runExceptT

-- | Manages the control signals (Heartbeat and Terminate) asynchronously while
-- the provided action performs a request
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

-- | Connects to the MQTT broker and creates a 'MQTTGRPCClient'
-- NB: Overwrites the '_msgCB' field in the 'MQTTConfig'
connectMQTTGRPC :: (MonadIO io) => Logger -> Config -> io MQTTGRPCClient
connectMQTTGRPC logger cfg = do
  resultChan <- newTChanIO

  let clientMQTTHandler :: MessageCallback
      clientMQTTHandler =
        SimpleCallback $ \_client topic mqttMessage _props -> do
          logDebug logger $ "clientMQTTHandler received message on topic: " <> unTopic topic <> "\nRaw: " <> decodeUtf8 mqttMessage
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
