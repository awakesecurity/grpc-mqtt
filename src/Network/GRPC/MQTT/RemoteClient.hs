{- 
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}

{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.RemoteClient (runRemoteClient) where

import Relude

import Network.GRPC.MQTT.Core (
  connectMQTT,
  heartbeatPeriodSeconds,
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
  MQTTConfig (_msgCB),
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
import System.IO (hPutStrLn)
import Turtle (NominalDiffTime)
import UnliftIO (timeout)
import UnliftIO.Async (Async, async, cancel, waitEither_, withAsync)
import UnliftIO.Exception (throwString, tryAny)

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
  -- | MQTT configuration for connecting to the MQTT broker
  MQTTConfig ->
  -- | Base topic which should uniquely identify the device
  Topic ->
  -- | A map from gRPC method names to functions that can make requests to an appropriate gRPC server
  MethodMap ->
  IO ()
runRemoteClient cfg baseTopic methodMap = do
  currentSessions <- newTVarIO mempty
  bracket (connectMQTT cfg{_msgCB = gatewayHandler currentSessions}) normalDisconnect $ \gatewayMQTTClient -> do
    -- Subscribe to listen for all gRPC requests
    let listeningTopic = baseTopic <> "/grpc/request/+/+"
    _ <- subscribe gatewayMQTTClient [(listeningTopic, subOptions{_subQoS = QoS1})] []

    waitForClient gatewayMQTTClient
 where
  gatewayHandler :: SessionMap -> MessageCallback
  gatewayHandler currentSessions = SimpleCallback $ \client topic mqttMessage _props -> do
    result <- tryAny $ case T.splitOn "/" topic of
      [_, _, "grpc", "request", service, method] ->
        let grpcMethod = encodeUtf8 ("/" <> service <> "/" <> method)
         in makeGRPCRequest methodMap currentSessions client grpcMethod mqttMessage
      [_, _, "grpc", "session", sessionId, "control"] -> manageSession currentSessions sessionId mqttMessage
      _ -> throwString $ "Failed to parse topic: " <> toString topic

    -- Catch and print any synchronous exception. We don't want an exception
    -- from an individual callback thread to take down the entire MQTT client.
    case result of
      Left err -> hPutStrLn stderr $ displayException err
      Right () -> pure ()

-- | Perform the local gRPC call and publish the response
makeGRPCRequest ::
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
makeGRPCRequest methodMap currentSessions client grpcMethod mqttMessage = do
  (WrappedMQTTRequest lResponseTopic timeLimit reqMetadata payload) <-
    case fromByteString (toStrict mqttMessage) of
      -- Really can't do anything if we can't parse out the response topic
      Left err -> throwString $ "Decode wrapped request failed" <> show err
      Right x -> pure x

  let responseTopic = toStrict lResponseTopic
  let publishResponse msg = publishq client responseTopic msg False QoS1 []

  publishResponseSequenced <- mkSequencedPublish publishResponse

  case lookup grpcMethod methodMap of
    Nothing ->
      publishResponse . wrapMQTTError $ "Failed to find client for: " <> decodeUtf8 grpcMethod
    -- Run Unary Request
    Just (ClientUnaryHandler handler) -> do
      response <- handler payload (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata)
      publishResponse $ wrapUnaryResponse response
    -- Run Server Streaming Request
    Just (ClientServerStreamHandler handler) -> do
      getSessionId currentSessions responseTopic >>= \case
        Left err -> publishResponse . wrapMQTTError $ toLazy err
        Right sessionId -> bracket (sessionInit sessionId) (sessionCleanup sessionId) waitWithHeartbeatMonitor
     where
      controlTopic :: Topic
      controlTopic = responseTopic <> "/control"

      runHandler :: IO ()
      runHandler = do
        handler payload (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata) (streamReader publishResponseSequenced)
          >>= publishResponseSequenced . wrapStreamResponse

      sessionInit :: Text -> IO Session
      sessionInit sessionId = do
        _ <- subscribe client [(controlTopic, subOptions{_subQoS = QoS1})] []

        newSession <-
          Session
            <$> async runHandler
            <*> newTMVarIO ()

        atomically $ modifyTVar' currentSessions (Map.insert sessionId newSession)

        return newSession

      sessionCleanup :: Text -> Session -> IO ()
      sessionCleanup sessionId session = do
        atomically $ modifyTVar' currentSessions (Map.delete sessionId)
        cancel $ handlerThread session
        _ <- unsubscribe client [controlTopic] []
        pure ()

      waitWithHeartbeatMonitor :: Session -> IO ()
      waitWithHeartbeatMonitor Session{..} =
        withAsync heartbeatMon $ \heartbeatThread ->
          waitEither_ handlerThread heartbeatThread
       where
        -- Wait slightly longer than the heartbeatPeriod to allow for network delays
        heartbeatMon = watchdog (heartbeatPeriodSeconds + 1) sessionHeartbeat

-- | Handles AuxControl signals from the "/control" topic
manageSession :: SessionMap -> SessionId -> LByteString -> IO ()
manageSession currentSessions sessionId mqttMessage =
  case fromByteString (toStrict mqttMessage) of
    Right (AuxControlMessage (Enumerated (Right AuxControlTerminate))) -> do
      mSession <- atomically $ do
        mSession <- Map.lookup sessionId <$> readTVar currentSessions
        modifyTVar' currentSessions (Map.delete sessionId)
        return mSession
      whenJust mSession (cancel . handlerThread)
    Right (AuxControlMessage (Enumerated (Right AuxControlAlive))) ->
      whenJustM
        (Map.lookup sessionId <$> readTVarIO currentSessions)
        (\Session{..} -> void . atomically $ tryPutTMVar sessionHeartbeat ())
    -- Unknown Control Message
    ctrl -> throwString $ "Unknown ctrl message: " <> show ctrl

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
    throwError "Session already exists"

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
