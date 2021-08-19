{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.RemoteClient (runRemoteClient) where

import Relude

import Network.GRPC.MQTT.Core (
  Logger,
  MQTTConnectionConfig,
  connectMQTT,
  heartbeatPeriodSeconds,
  logDebug,
  logErr,
  logInfo,
  logWarn,
  setCallback,
 )
import Network.GRPC.MQTT.Sequenced (mkSequencedPublish)
import Network.GRPC.MQTT.Types (
  ClientHandler (ClientServerStreamHandler, ClientUnaryHandler),
  MethodMap,
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
import qualified Data.Text as T
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
  Topic,
  normalDisconnect,
  publishq,
  subOptions,
  subscribe,
  unsubscribe,
  waitForClient,
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
import UnliftIO.Async (Async, async, cancel, waitEither, withAsync)
import UnliftIO.Exception (throwString, try, tryAny)

-- | Represents the session ID for a request
type SessionId = Text

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
  MQTTConnectionConfig ->
  -- | Base topic which should uniquely identify the device
  Topic ->
  -- | A map from gRPC method names to functions that can make requests to an appropriate gRPC server
  MethodMap ->
  IO ()
runRemoteClient logger cfg baseTopic methodMap = do
  currentSessions <- newTVarIO mempty
  let gatewayConfig = cfg & setCallback (gatewayHandler currentSessions)
  bracket (connectMQTT gatewayConfig) normalDisconnect $ \gatewayMQTTClient -> do
    logInfo logger "Connected to MQTT Broker"

    -- Subscribe to listen for all gRPC requests
    let listeningTopic = baseTopic <> "/grpc/request/+/+"
    (subResults, _) <- subscribe gatewayMQTTClient [(listeningTopic, subOptions{_subQoS = QoS1})] []
    case subResults of
      [Left subErr] ->
        logErr logger $
          "Remote Client failed to subscribe to the topic: " <> listeningTopic <> "Reason: " <> show subErr
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
    logInfo logger $ "Remote Client received request at topic: " <> topic

    result <- tryAny $ case T.splitOn "/" topic of
      [_, _, "grpc", "request", service, method] ->
        let grpcMethod = encodeUtf8 ("/" <> service <> "/" <> method)
         in makeGRPCRequest logger methodMap currentSessions client grpcMethod mqttMessage
      [_, _, "grpc", "session", sessionId, "control"] -> manageSession logger currentSessions sessionId mqttMessage
      _ -> logErr logger $ "Failed to parse topic: " <> topic

    -- Catch and print any synchronous exception. We don't want an exception
    -- from an individual callback thread to take down the entire MQTT client.
    whenLeft_ result $ \err ->
      logErr logger $ "gatewayHandler terminated with exception: " <> toText (displayException err)

-- | Perform the local gRPC call and publish the response
makeGRPCRequest ::
  Logger ->
  -- | A map from gRPC method names to functions that can make requests to an appropriate gRPC server
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
makeGRPCRequest logger methodMap currentSessions client grpcMethod mqttMessage = do
  logInfo logger $ "Received request for the gRPC method: " <> decodeUtf8 grpcMethod

  (WrappedMQTTRequest lResponseTopic timeLimit reqMetadata payload) <-
    case fromByteString (toStrict mqttMessage) of
      Left err -> throwString $ "Failed to decode MQTT message: " <> show err
      Right x -> pure x

  let responseTopic = toStrict lResponseTopic
  let publishResponse msg = do
        logDebug logger $
          "Publishing response to topic: " <> responseTopic <> " Raw message: " <> decodeUtf8 msg
        publishq client responseTopic msg False QoS1 []

  logDebug logger $
    "Wrapped request data: "
      <> "Response Topic: "
      <> responseTopic
      <> "Timeout: "
      <> show timeLimit
      <> "Metadata: "
      <> show reqMetadata

  publishResponseSequenced <- mkSequencedPublish publishResponse

  case lookup grpcMethod methodMap of
    Nothing -> do
      let errMsg = "Failed to find gRPC client for: " <> decodeUtf8 grpcMethod
      logErr logger (toStrict errMsg)
      publishResponse $ wrapMQTTError errMsg
    -- Run Unary Request
    Just (ClientUnaryHandler handler) -> do
      logDebug logger $ "Found unary client handler for: " <> decodeUtf8 grpcMethod
      response <- handler payload (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata)
      publishResponse $ wrapUnaryResponse response
    -- Run Server Streaming Request
    Just (ClientServerStreamHandler handler) -> do
      logDebug logger $ "Found streaming client handler for: " <> decodeUtf8 grpcMethod
      getSessionId currentSessions responseTopic >>= \case
        Left err -> do
          logErr logger err
          publishResponse . wrapMQTTError $ toLazy err
        Right sessionId -> do
          bracket (sessionInit sessionId) (sessionCleanup sessionId) waitWithHeartbeatMonitor
     where
      controlTopic :: Topic
      controlTopic = responseTopic <> "/control"

      runHandler :: IO ()
      runHandler = do
        handler payload (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata) (streamReader publishResponseSequenced)
          >>= publishResponseSequenced . wrapStreamResponse

      sessionInit :: Text -> IO Session
      sessionInit sessionId = do
        (subResults, _) <- subscribe client [(controlTopic, subOptions{_subQoS = QoS1})] []
        case subResults of
          [Left subErr] ->
            throwString $
              "Failed to subscribe to the topic: " <> toString controlTopic <> "Reason: " <> show subErr
          _ -> do
            logInfo logger $ "Begin new streaming session: " <> sessionId

            newSession <-
              Session
                <$> async runHandler
                <*> newTMVarIO ()

            atomically $ modifyTVar' currentSessions (Map.insert sessionId newSession)

            return newSession

      sessionCleanup :: Text -> Session -> IO ()
      sessionCleanup sessionId session = do
        logInfo logger $ "Cleanup streaming session: " <> sessionId
        atomically $ modifyTVar' currentSessions (Map.delete sessionId)
        cancel $ handlerThread session
        _ <- unsubscribe client [controlTopic] []
        pure ()

      waitWithHeartbeatMonitor :: Session -> IO ()
      waitWithHeartbeatMonitor Session{..} =
        withAsync heartbeatMon $ \heartbeatThread ->
          waitEither handlerThread heartbeatThread >>= \case
            Left () -> logDebug logger "handlerThread completed"
            Right () -> logWarn logger "Timed out waiting for heartbeat"
       where
        -- Wait slightly longer than the heartbeatPeriod to allow for network delays
        heartbeatMon = watchdog (heartbeatPeriodSeconds + 1) sessionHeartbeat

-- | Handles AuxControl signals from the "/control" topic
manageSession :: Logger -> SessionMap -> SessionId -> LByteString -> IO ()
manageSession logger currentSessions sessionId mqttMessage =
  case fromByteString (toStrict mqttMessage) of
    Right (AuxControlMessage (Enumerated (Right AuxControlTerminate))) -> do
      logInfo logger $ "Received terminate message for session: " <> sessionId

      mSession <- atomically $ do
        mSession <- Map.lookup sessionId <$> readTVar currentSessions
        modifyTVar' currentSessions (Map.delete sessionId)
        return mSession
      whenJust mSession (cancel . handlerThread)
    Right (AuxControlMessage (Enumerated (Right AuxControlAlive))) -> do
      logDebug logger $ "Received heartbeat message for session: " <> sessionId

      whenJustM
        (Map.lookup sessionId <$> readTVarIO currentSessions)
        (\Session{..} -> void . atomically $ tryPutTMVar sessionHeartbeat ())
    Right ctrl ->
      logWarn logger $ "Received unknown control message: " <> show ctrl <> " for session: " <> sessionId
    Left err ->
      logErr logger $ "Failed to parse control message for session " <> sessionId <> ": " <> show err

{- | Parses the session ID out of the response topic and checks that
 the session ID is not already in use
-}
getSessionId :: SessionMap -> Topic -> IO (Either Text Text)
getSessionId sessions topic = runExceptT $ do
  sessionId <-
    case T.splitOn "/" topic of
      (_ : _ : _ : _ : sessionId : _) -> pure sessionId
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
streamReader publishResponse _cc initMetadata recv = do
  publishResponse $ wrapStreamInitMetadata initMetadata
  readLoop
 where
  readLoop =
    recv >>= \case
      Left err -> publishResponse $ wrapStreamResponse @a (ClientErrorResponse $ ClientIOError err)
      Right chunk -> do
        publishResponse $ wrapStreamChunk chunk
        when (isJust chunk) readLoop
