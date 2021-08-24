{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.RemoteClient (runRemoteClient) where

import Relude

import Network.GRPC.MQTT.Core (
  MQTTGRPCConfig (_msgCB, mqttMsgSizeLimit),
  connectMQTT,
  heartbeatPeriodSeconds,
  toFilter,
 )
import Network.GRPC.MQTT.Logging (
  Logger,
  logDebug,
  logErr,
  logInfo,
  logWarn,
 )
import Network.GRPC.MQTT.Sequenced (mkPublish)
import Network.GRPC.MQTT.Types (
  ClientHandler (ClientServerStreamHandler, ClientUnaryHandler),
  MethodMap,
  SessionId,
 )
import Network.GRPC.MQTT.Wrapping (
  toMetadataMap,
  wrapMQTTError,
  wrapStreamChunk,
  wrapStreamInitMetadata,
  wrapStreamResponse,
  wrapUnaryResponse,
 )

import Control.Exception (bracket)
import Control.Monad.Except (throwError)
import Data.HashMap.Strict (lookup)
import qualified Data.Map.Strict as Map
import Network.GRPC.HighLevel (GRPCIOError)
import qualified Network.GRPC.HighLevel as HL
import Network.GRPC.HighLevel.Client (
  ClientError (ClientIOError),
  ClientResult (ClientErrorResponse),
 )
import Network.MQTT.Client (
  MQTTClient,
  MQTTException,
  MessageCallback (SimpleCallback),
  QoS (QoS1),
  SubOptions (_subQoS),
  normalDisconnect,
  subOptions,
  subscribe,
  unsubscribe,
  waitForClient,
 )
import Network.MQTT.Topic (
  Filter (unFilter),
  Topic (unTopic),
  mkTopic,
  split,
 )
import Proto.Mqtt (
  AuxControl (AuxControlAlive, AuxControlTerminate),
  AuxControlMessage (AuxControlMessage),
  WrappedMQTTRequest (WrappedMQTTRequest),
 )
import Proto3.Suite (
  Enumerated (Enumerated),
  Message,
  fromByteString,
 )
import Turtle (NominalDiffTime)
import UnliftIO (timeout)
import UnliftIO.Async (
  Async,
  async,
  cancel,
  waitEither,
  withAsync,
 )
import UnliftIO.Exception (throwString, try, tryAny)

-- | A shared map of all currently running sessions
type SessionMap = TVar (Map SessionId Session)

-- | Holds information for managing a session
data Session = Session
  { -- | Handle of the the thread making the gRPC request
    handlerThread :: Async ()
  , -- | Variable that must be touched at 'heartbeatPeriod' rate or the session will be terminated
    sessionHeartbeat :: TMVar ()
  }

-- | The serverside adapter acts as a remote gRPC client.
runRemoteClient ::
  Logger ->
  -- | MQTT configuration for connecting to the MQTT broker
  MQTTGRPCConfig ->
  -- | Base topic which should uniquely identify the device
  Topic ->
  -- | A map from gRPC method names to functions that can make requests to an appropriate gRPC server
  MethodMap ->
  IO ()
runRemoteClient logger cfg baseTopic methodMap = do
  currentSessions <- newTVarIO mempty
  let gatewayConfig = cfg{_msgCB = gatewayHandler currentSessions}
  bracket (connectMQTT gatewayConfig) normalDisconnect $ \gatewayMQTTClient -> do
    logInfo logger "Connected to MQTT Broker"

    -- Subscribe to listen for all gRPC requests
    let grpcRequestsFilter = toFilter baseTopic <> "grpc" <> "request" <> "+" <> "+"
    (subResults, _) <- subscribe gatewayMQTTClient [(grpcRequestsFilter, subOptions{_subQoS = QoS1})] []
    case subResults of
      [Left subErr] ->
        logErr logger $
          "Remote Client failed to subscribe to the topic: " <> unFilter grpcRequestsFilter <> "Reason: " <> show subErr
      _ -> do
        try (waitForClient gatewayMQTTClient) >>= \case
          Left (e :: MQTTException) ->
            logErr logger $
              "MQTT client connection terminated with exception: " <> toText (displayException e)
          Right () ->
            logInfo
              logger
              "MQTT client connection terminated normally"
 where
  gatewayHandler :: SessionMap -> MessageCallback
  gatewayHandler currentSessions = SimpleCallback $ \client topic mqttMessage _props -> do
    logInfo logger $ "Remote Client received request at topic: " <> unTopic topic

    result <- tryAny $ case split topic of
      [_, _, "grpc", "request", service, method] -> do
        let grpcMethod = encodeUtf8 ("/" <> unTopic service <> "/" <> unTopic method)
        let maxMsgSize = fromIntegral $ mqttMsgSizeLimit cfg
        makeGRPCRequest logger maxMsgSize methodMap currentSessions client grpcMethod mqttMessage
      [_, _, "grpc", "session", sessionId, "control"] -> manageSession logger currentSessions (unTopic sessionId) mqttMessage
      _ -> logErr logger $ "Failed to parse topic: " <> unTopic topic

    -- Catch and print any synchronous exception. We don't want an exception
    -- from an individual callback thread to take down the entire MQTT client.
    whenLeft_ result $ \err ->
      logErr logger $ "gatewayHandler terminated with exception: " <> toText (displayException err)

-- | Perform the local gRPC call and publish the response
makeGRPCRequest ::
  Logger ->
  -- | A map from gRPC method names to functions that can make requests to an appropriate gRPC server
  Int64 ->
  -- | Maximum MQTT message size
  MethodMap ->
  -- | The map of the current sessions
  SessionMap ->
  -- | The MQTT client
  MQTTClient ->
  -- | The full gRPC method name
  ByteString ->
  -- | The raw MQTT message
  LByteString ->
  IO ()
makeGRPCRequest logger maxMsgSize methodMap currentSessions client grpcMethod mqttMessage = do
  logInfo logger $ "Received request for the gRPC method: " <> decodeUtf8 grpcMethod

  (WrappedMQTTRequest lResponseTopic timeLimit reqMetadata payload) <-
    case fromByteString (toStrict mqttMessage) of
      Left err -> throwString $ "Failed to decode MQTT message: " <> show err
      Right x -> pure x

  responseTopic <-
    case mkTopic (toStrict lResponseTopic) of
      Nothing -> throwString $ "Invalid response topic: " <> toString lResponseTopic
      Just topic -> pure topic

  let logPrefix = case split responseTopic of
        (_ : _ : _ : _ : sessionId : _) -> "[" <> unTopic sessionId <> "] "
        _ -> "[??] "
  let tagSession msg = logPrefix <> msg

  logDebug logger . tagSession $
    unlines
      [ "Wrapped request data: "
      , "  Response Topic: " <> unTopic responseTopic
      , "  Timeout: " <> show timeLimit
      , "  Metadata: " <> show (toMetadataMap <$> reqMetadata)
      ]

  publish <- mkPublish (logDebug logger . tagSession) responseTopic client maxMsgSize

  case lookup grpcMethod methodMap of
    Nothing -> do
      let errMsg = "Failed to find gRPC client for: " <> decodeUtf8 grpcMethod
      logErr logger . tagSession $ toStrict errMsg
      publish $ wrapMQTTError errMsg
    -- Run Unary Request
    Just (ClientUnaryHandler handler) -> do
      logDebug logger . tagSession $ "Found unary client handler for: " <> decodeUtf8 grpcMethod
      response <- handler payload (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata)
      publish $ wrapUnaryResponse response

    -- Run Server Streaming Request
    Just (ClientServerStreamHandler handler) -> do
      logDebug logger . tagSession $ "Found streaming client handler for: " <> decodeUtf8 grpcMethod
      getSessionId currentSessions responseTopic >>= \case
        Left err -> do
          logErr logger . tagSession $ err
          publish . wrapMQTTError $ toLazy err
        Right sessionId -> do
          bracket (sessionInit sessionId) (sessionCleanup sessionId) waitWithHeartbeatMonitor
     where
      controlFilter :: Filter
      controlFilter = toFilter responseTopic <> "control"

      runHandler :: IO ()
      runHandler = do
        handler payload (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata) (streamReader publish)
          >>= publish . wrapStreamResponse

      sessionInit :: Text -> IO Session
      sessionInit sessionId = do
        (subResults, _) <- subscribe client [(controlFilter, subOptions{_subQoS = QoS1})] []
        case subResults of
          [Left subErr] ->
            throwString $
              "Failed to subscribe to the topic: " <> show controlFilter <> "Reason: " <> show subErr
          _ -> do
            logInfo logger . tagSession $ "Begin new streaming session"

            newSession <-
              Session
                <$> async runHandler
                <*> newTMVarIO ()

            atomically $ modifyTVar' currentSessions (Map.insert sessionId newSession)

            return newSession

      sessionCleanup :: Text -> Session -> IO ()
      sessionCleanup sessionId session = do
        logInfo logger . tagSession $ "Cleanup streaming session"
        atomically $ modifyTVar' currentSessions (Map.delete sessionId)
        cancel $ handlerThread session
        _ <- unsubscribe client [controlFilter] []
        pure ()

      waitWithHeartbeatMonitor :: Session -> IO ()
      waitWithHeartbeatMonitor Session{..} =
        withAsync heartbeatMon $ \heartbeatThread ->
          waitEither handlerThread heartbeatThread >>= \case
            Left () -> logDebug logger . tagSession $ "handlerThread completed"
            Right () -> logWarn logger . tagSession $ "Timed out waiting for heartbeat"
       where
        -- Wait slightly longer than the heartbeatPeriod to allow for network delays
        heartbeatMon = watchdog (heartbeatPeriodSeconds + 1) sessionHeartbeat

-- | Handles AuxControl signals from the "/control" topic
manageSession :: Logger -> SessionMap -> SessionId -> LByteString -> IO ()
manageSession logger currentSessions sessionId mqttMessage = do
  let tagSession msg = "[" <> sessionId <> "] " <> msg
  case fromByteString (toStrict mqttMessage) of
    Right (AuxControlMessage (Enumerated (Right AuxControlTerminate))) -> do
      logInfo logger . tagSession $ "Received terminate message"
      mSession <- atomically $ do
        mSession <- Map.lookup sessionId <$> readTVar currentSessions
        modifyTVar' currentSessions (Map.delete sessionId)
        return mSession
      whenJust mSession (cancel . handlerThread)
    Right (AuxControlMessage (Enumerated (Right AuxControlAlive))) -> do
      logDebug logger . tagSession $ "Received heartbeat message"
      whenJustM
        (Map.lookup sessionId <$> readTVarIO currentSessions)
        (\Session{..} -> void . atomically $ tryPutTMVar sessionHeartbeat ())
    Right ctrl ->
      logWarn logger . tagSession $ "Received unknown control message: " <> show ctrl
    Left err ->
      logErr logger . tagSession $ "Failed to parse control message: " <> show err

{- | Parses the session ID out of the response topic and checks that
 the session ID is not already in use
-}
getSessionId :: SessionMap -> Topic -> IO (Either Text SessionId)
getSessionId sessions topic = runExceptT $ do
  sessionId <-
    case split topic of
      (_ : _ : _ : _ : sessionId : _) -> pure $ unTopic sessionId
      _ -> throwError "Unable to read sessionId from topic"

  sessionExists <- Map.member sessionId <$> readTVarIO sessions
  when sessionExists $
    throwError $ "Session already exists: " <> sessionId

  return sessionId

{- | Runs indefinitely as long as the `TMVar` is filled every `timeLimit` seconds
 Intended to be used with 'race'
-}
watchdog :: NominalDiffTime -> TMVar () -> IO ()
watchdog timeLimit var = loop
 where
  uSecs = floor $ timeLimit * 1000000
  loop =
    whenJustM
      (timeout uSecs $ atomically (takeTMVar var))
      (const loop)

-- | Passes chunks of data from a gRPC stream onto MQTT
streamReader ::
  forall a clientcall.
  (Message a) =>
  (LByteString -> IO ()) ->
  clientcall ->
  HL.MetadataMap ->
  IO (Either GRPCIOError (Maybe a)) ->
  IO ()
streamReader publish _cc initMetadata recv = do
  publish $ wrapStreamInitMetadata initMetadata
  readLoop
 where
  readLoop =
    recv >>= \case
      Left err -> publish $ wrapStreamResponse @a (ClientErrorResponse $ ClientIOError err)
      Right chunk -> do
        publish $ wrapStreamChunk chunk
        when (isJust chunk) readLoop
