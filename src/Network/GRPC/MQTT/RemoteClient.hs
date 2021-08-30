{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.RemoteClient (runRemoteClient) where

import Relude

import Network.GRPC.MQTT.Core (
  MQTTGRPCConfig (mqttMsgSizeLimit, _msgCB),
  connectMQTT,
  heartbeatPeriodSeconds,
  subscribeOrThrow,
  toFilter,
 )
import Network.GRPC.MQTT.Logging (
  Logger,
  logDebug,
  logErr,
  logInfo,
  logWarn,
 )
import Network.GRPC.MQTT.Sequenced (mkPacketizedPublish, mkPacketizedRead)
import Network.GRPC.MQTT.Types (
  ClientHandler (ClientClientStreamHandler, ClientServerStreamHandler, ClientUnaryHandler),
  MethodMap,
  SessionId,
 )
import Network.GRPC.MQTT.Wrapping (
  toMetadataMap,
  unwrapStreamChunk,
  wrapClientStreamResponse,
  wrapMQTTError,
  wrapStreamChunk,
  wrapStreamInitMetadata,
  wrapStreamResponse,
  wrapUnaryResponse,
 )

import Control.Exception (bracket)
import Data.HashMap.Strict (lookup)
import Data.List (stripPrefix)
import qualified Data.Map.Strict as Map
import Network.GRPC.HighLevel (GRPCIOError, StreamSend)
import qualified Network.GRPC.HighLevel as HL
import Network.GRPC.HighLevel.Client (
  ClientError (ClientIOError),
  ClientResult (ClientErrorResponse),
 )
import Network.GRPC.MQTT (MQTTException (MQTTException))
import Network.MQTT.Client (
  MQTTClient,
  MessageCallback (SimpleCallback),
  normalDisconnect,
  waitForClient,
 )
import Network.MQTT.Topic (
  Topic (unTopic),
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
import UnliftIO (TChan, newTChanIO, timeout, writeTChan)
import UnliftIO.Async (Async, async, cancel, race_)
import UnliftIO.Exception (finally, handle, handleAny, throwString)

-- | A shared map of all currently running sessions
type SessionMap = TVar (Map SessionId Session)

-- | Holds information for managing a session
data Session = Session
  { -- | Handle of the the thread making the gRPC request
    handlerThread :: Async ()
  , -- | Variable that must be touched at 'heartbeatPeriod' rate or the session will be terminated
    sessionHeartbeat :: TMVar ()
  , requestChan :: TChan LByteString
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

    handle (logException "MQTT client connection") $ do
      let grpcRequestsFilter = toFilter baseTopic <> "grpc" <> "request" <> "+" <> "+" <> "+"
      let controlFilter = toFilter baseTopic <> "grpc" <> "session" <> "+" <> "control"
      subscribeOrThrow gatewayMQTTClient [grpcRequestsFilter, controlFilter]

      waitForClient gatewayMQTTClient

      logInfo logger "MQTT client connection terminated normally"
 where
  gatewayHandler :: SessionMap -> MessageCallback
  gatewayHandler currentSessions = SimpleCallback $ \client topic mqttMessage _props -> do
    logInfo logger $ "Remote Client received request at topic: " <> unTopic topic

    -- Catch and log any synchronous exception. We don't want an exception
    -- from an individual callback thread to take down the entire MQTT client.
    handleAny (logException "gatewayHandler") $ do
      let getSession :: SessionId -> IO (Maybe Session)
          getSession sessionId = Map.lookup sessionId <$> readTVarIO currentSessions
      case stripPrefix (split baseTopic) (split topic) of
        Nothing -> bug $ MQTTException "Base topic mismatch"
        Just ["grpc", "request", sessionId, service, method] -> do
          session <-
            getSession (unTopic sessionId) >>= \case
              Just s -> pure s
              Nothing -> do
                let grpcMethod = encodeUtf8 ("/" <> unTopic service <> "/" <> unTopic method)
                let maxMsgSize = fromIntegral $ mqttMsgSizeLimit cfg
                createNewSession logger currentSessions maxMsgSize methodMap client baseTopic sessionId grpcMethod
          atomically $ writeTChan (requestChan session) mqttMessage
        Just ["grpc", "session", sessionId, "control"] -> do
          getSession (unTopic sessionId) >>= \case
            Nothing -> logInfo logger "Received control message for non-existant session"
            Just session -> controlMsgHandler logger (unTopic sessionId) session mqttMessage
        _ -> logErr logger $ "Failed to parse topic: " <> unTopic topic

  logException :: Text -> SomeException -> IO ()
  logException name e =
    logErr logger $
      name <> " terminated with exception: " <> toText (displayException e)

createNewSession ::
  Logger ->
  SessionMap ->
  Int64 ->
  MethodMap ->
  MQTTClient ->
  Topic ->
  Topic ->
  ByteString ->
  IO Session
createNewSession logger currentSessions maxMsgSize methodMap client baseTopic sessionId grpcMethod = do
  reqChan <- newTChanIO
  heartbeatVar <- newTMVarIO ()

  let sessionHandler :: IO ()
      sessionHandler =
        requestHandlerWithWatchdog
          `finally` atomically (modifyTVar' currentSessions (Map.delete (unTopic sessionId)))
       where        
        requestHandlerWithWatchdog =
          race_
            heartbeatMon
            (requestHandler logger reqChan maxMsgSize methodMap client grpcMethod sessionId baseTopic)
        heartbeatMon = do
          watchdog (heartbeatPeriodSeconds + 1) heartbeatVar
          logWarn logger "watchdog timed out"

  sessionThread <- async sessionHandler

  let newSession = Session sessionThread heartbeatVar reqChan
  atomically $ modifyTVar' currentSessions (Map.insert (unTopic sessionId) newSession)

  return newSession

-- | Perform the local gRPC call and publish the response
requestHandler ::
  Logger ->
  TChan LByteString ->
  -- | A map from gRPC method names to functions that can make requests to an appropriate gRPC server
  Int64 ->
  -- | Maximum MQTT message size
  MethodMap ->
  -- | The MQTT client
  MQTTClient ->
  -- | The full gRPC method name
  ByteString ->
  Topic ->
  Topic ->
  IO ()
requestHandler logger reqChan maxMsgSize methodMap client grpcMethod sessionId baseTopic = do
  let tagSession msg = "[" <> unTopic sessionId <> "]" <> msg
  logInfo logger . tagSession $ "Received request for the gRPC method: " <> decodeUtf8 grpcMethod

  readRequest <- mkPacketizedRead reqChan
  let readUnsafe = do
        readRequest >>= \case
          Left _ -> throwString "Read failed"
          Right m -> pure m
  mqttMessage <- readUnsafe

  (WrappedMQTTRequest timeLimit reqMetadata payload) <-
    case fromByteString (toStrict mqttMessage) of
      Left err -> throwString $ "Failed to decode MQTT message: " <> show err
      Right x -> pure x

  logDebug logger . tagSession $
    unlines
      [ "Wrapped request data: "
      , "  Timeout: " <> show timeLimit
      , "  Metadata: " <> show (toMetadataMap <$> reqMetadata)
      ]

  let responseTopic = baseTopic <> "grpc" <> "session" <> sessionId
  publish <- mkPacketizedPublish client maxMsgSize responseTopic

  case lookup grpcMethod methodMap of
    Nothing -> do
      let errMsg = "Failed to find gRPC client for: " <> decodeUtf8 grpcMethod
      logErr logger . tagSession $ toStrict errMsg
      publish $ wrapMQTTError errMsg
    -- Run Unary Request
    Just (ClientUnaryHandler handler) -> do
      response <- handler payload (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata)
      publish $ wrapUnaryResponse response

    -- Run Client Streaming Request
    Just (ClientClientStreamHandler handler) -> do
      let readChan :: (Message request) => IO (Maybe request)
          readChan = do
            r <- readRequest
            case unwrapStreamChunk (toStrict <$> r) of
              Left _ -> pure Nothing
              Right x -> pure x

      response <- handler (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata) (streamSend readChan)
      publish $ wrapClientStreamResponse response

    -- Run Server Streaming Request
    Just (ClientServerStreamHandler handler) -> do
      response <- handler payload (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata) (streamReader publish)
      publish $ wrapStreamResponse response

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

-- StreamSend request ~ (request -> IO (Either GRPCIOError ()))
streamSend :: forall request. IO (Maybe request) -> StreamSend request -> IO ()
streamSend readChunk send = loop
 where
  loop = whenJustM readChunk $ \chunk -> do
    _ <- send chunk
    loop

-- | Handles AuxControl signals from the "/control" topic
controlMsgHandler :: Logger -> SessionId -> Session -> LByteString -> IO ()
controlMsgHandler logger sessionId session mqttMessage = do
  let tagSession msg = "[" <> sessionId <> "] " <> msg
  case fromByteString (toStrict mqttMessage) of
    Right (AuxControlMessage (Enumerated (Right AuxControlTerminate))) -> do
      logInfo logger . tagSession $ "Received terminate message"
      cancel $ handlerThread session
    Right (AuxControlMessage (Enumerated (Right AuxControlAlive))) -> do
      logDebug logger . tagSession $ "Received heartbeat message"
      void . atomically $ tryPutTMVar (sessionHeartbeat session) ()
    Right ctrl ->
      logWarn logger . tagSession $ "Received unknown control message: " <> show ctrl
    Left err ->
      logErr logger . tagSession $ "Failed to parse control message: " <> show err
