{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.RemoteClient (runRemoteClient) where

import Relude

import Network.GRPC.MQTT.Core
  ( MQTTGRPCConfig (mqttMsgSizeLimit, _msgCB),
    connectMQTT,
    heartbeatPeriodSeconds,
    subscribeOrThrow,
  )
import Network.GRPC.MQTT.Logging
  ( Logger (log),
    logDebug,
    logErr,
    logInfo,
    logWarn,
  )
import Network.GRPC.MQTT.Sequenced (mkPacketizedPublish, mkPacketizedRead)
import Network.GRPC.MQTT.Types
  ( ClientHandler (..),
    MethodMap,
    SessionId,
  )
import Network.GRPC.MQTT.Wrapping
  ( fromLazyByteString,
    fromMetadataMap,
    remoteError,
    toMetadataMap,
    unwrapStreamChunk,
    wrapResponse,
    wrapStreamChunk,
  )
import Proto.Mqtt
  ( AuxControl (AuxControlAlive, AuxControlTerminate),
    AuxControlMessage (AuxControlMessage),
    MQTTRequest (MQTTRequest),
    RemoteError,
  )

import Control.Exception (bracket)
import Control.Monad.Except (MonadError (throwError))
import Data.HashMap.Strict (lookup)
import Data.List (stripPrefix)
import qualified Data.Map.Strict as Map
import Network.GRPC.HighLevel (GRPCIOError, StreamSend)
import qualified Network.GRPC.HighLevel as HL
import Network.GRPC.HighLevel.Client
  ( ClientError (ClientIOError),
    ClientResult (ClientErrorResponse),
  )
import Network.GRPC.MQTT (MQTTException (MQTTException))
import Network.MQTT.Client
  ( MQTTClient,
    MessageCallback (SimpleCallback),
    normalDisconnect,
    waitForClient,
  )
import Network.MQTT.Topic
  ( Topic (unTopic),
    split,
    toFilter,
  )
import Proto3.Suite
  ( Enumerated (Enumerated),
    Message,
    fromByteString,
    toLazyByteString,
  )
import Turtle (NominalDiffTime)
import UnliftIO (TChan, newTChanIO, timeout, writeTChan)
import UnliftIO.Async (Async, async, cancel, race_)
import UnliftIO.Exception (finally, handle, handleAny)

-- | A shared map of all currently running sessions
type SessionMap = TVar (Map SessionId Session)

-- | Holds information for managing a session
data Session = Session
  { -- | Handle of the the thread making the gRPC request
    handlerThread :: Async ()
  , -- | Variable that must be touched at 'heartbeatPeriod' rate or the session will be terminated
    sessionHeartbeat :: TMVar ()
  , -- | Channel for passing MQTT messages to handler thread
    requestChan :: TChan LByteString
  }

-- | Parameters for creating a new 'Session'
data SessionArgs = SessionArgs
  { sessionLogger :: Logger
  , sessionMap :: SessionMap
  , client :: MQTTClient
  , methodMap :: MethodMap
  , baseTopic :: Topic
  , sessionId :: Topic
  , maxMsgSize :: Int64
  , grpcMethod :: ByteString
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
  sharedSessionMap <- newTVarIO mempty
  let gatewayConfig = cfg{_msgCB = gatewayHandler sharedSessionMap}
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
    gatewayHandler sharedSessionMap = SimpleCallback $ \client topic mqttMessage _props -> do
      logInfo logger $ "Remote Client received request at topic: " <> unTopic topic

      -- Catch and log any synchronous exception. We don't want an exception
      -- from an individual callback thread to take down the entire MQTT client.
      handleAny (logException "gatewayHandler") $ do
        let getSession :: SessionId -> IO (Maybe Session)
            getSession sessionId = Map.lookup sessionId <$> readTVarIO sharedSessionMap

        case stripPrefix (split baseTopic) (split topic) of
          Nothing -> bug $ MQTTException "Base topic mismatch"
          Just ["grpc", "request", sessionId, service, method] -> do
            session <-
              getSession (unTopic sessionId) `whenNothingM` do
                let taggedLog msg = log logger $ "[" <> unTopic sessionId <> "] " <> msg
                createNewSession
                  SessionArgs
                    { sessionLogger = logger{log = taggedLog}
                    , sessionMap = sharedSessionMap
                    , client = client
                    , methodMap = methodMap
                    , baseTopic = baseTopic
                    , sessionId = sessionId
                    , maxMsgSize = fromIntegral $ mqttMsgSizeLimit cfg
                    , grpcMethod = encodeUtf8 ("/" <> unTopic service <> "/" <> unTopic method)
                    }
            atomically $ writeTChan (requestChan session) mqttMessage
          Just ["grpc", "session", sessionId, "control"] -> do
            let taggedLog msg = log logger $ "[" <> unTopic sessionId <> "] " <> msg
            let taggedLogger = logger{log = taggedLog}
            getSession (unTopic sessionId) >>= \case
              Nothing -> logInfo taggedLogger "Received control message for non-existant session"
              Just session -> controlMsgHandler taggedLogger (unTopic sessionId) session mqttMessage
          _ -> logErr logger $ "Failed to parse topic: " <> unTopic topic

    logException :: Text -> SomeException -> IO ()
    logException name e =
      logErr logger $
        name <> " terminated with exception: " <> toText (displayException e)

{- | Creates a new 'Session'
 Spawns a thread to handle a request with a watchdog timer to
 monitor the heartbeat signal.

 The new 'Session' is inserted into the global 'SessionMap' and
 is removed by the handler thread upon completion.
-}
createNewSession :: SessionArgs -> IO Session
createNewSession args@SessionArgs{..} = do
  reqChan <- newTChanIO
  heartbeatVar <- newTMVarIO ()

  let sessionHandler :: IO ()
      sessionHandler =
        requestHandlerWithWatchdog
          `finally` atomically (modifyTVar' sessionMap (Map.delete (unTopic sessionId)))
        where
          requestHandlerWithWatchdog :: IO ()
          requestHandlerWithWatchdog =
            race_
              heartbeatMonitor
              (requestHandler args reqChan)
          heartbeatMonitor :: IO ()
          heartbeatMonitor = do
            watchdog (heartbeatPeriodSeconds + 1) heartbeatVar
            logWarn sessionLogger "watchdog timed out"

  sessionThread <- async sessionHandler

  let newSession = Session sessionThread heartbeatVar reqChan
  atomically $ modifyTVar' sessionMap (Map.insert (unTopic sessionId) newSession)

  return newSession

-- | Perform the local gRPC call and publish the response
requestHandler :: SessionArgs -> TChan LByteString -> IO ()
requestHandler SessionArgs{..} reqChan = do
  logInfo sessionLogger $ "Received request for the gRPC method: " <> decodeUtf8 grpcMethod

  let responseTopic = baseTopic <> "grpc" <> "session" <> sessionId
  publishRsp' <- mkPacketizedPublish client maxMsgSize responseTopic
  let publishToResponseTopic :: forall r. Message r => r -> IO ()
      publishToResponseTopic = publishRsp' . toLazyByteString

  publishErrors publishToResponseTopic . runExceptT $ do
    clientHandler <-
      lookup grpcMethod methodMap
        `whenNothing` throwError (remoteError $ "Failed to find gRPC client for: " <> decodeUtf8 grpcMethod)

    readRequest <- liftIO $ mkPacketizedRead reqChan
    mqttMessage <- readRequest

    (MQTTRequest timeLimit reqMetadata payload) <- hoistEither (fromLazyByteString mqttMessage)

    logDebug sessionLogger $
      unlines
        [ "Wrapped request data: "
        , "  Timeout: " <> show timeLimit
        , "  Metadata: " <> show (toMetadataMap <$> reqMetadata)
        ]

    liftIO $ case clientHandler of
      -- Run Unary Request
      ClientUnaryHandler handler -> do
        response <- handler payload (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata)
        publishToResponseTopic $ wrapResponse response

      -- Run Client Streaming Request
      ClientClientStreamHandler handler -> do
        let readStreamChunk :: (Message request) => MaybeT IO request
            readStreamChunk = do
              res <- exceptToMaybeT readRequest
              case unwrapStreamChunk res of
                Left _ -> empty
                Right c -> hoistMaybe c

        response <- handler (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata) (streamSend readStreamChunk)
        publishToResponseTopic $ wrapResponse response

      -- Run Server Streaming Request
      ClientServerStreamHandler handler -> do
        response <- handler payload (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata) (streamReader publishToResponseTopic)
        publishToResponseTopic $ wrapResponse response
  where
    publishErrors :: (RemoteError -> IO ()) -> IO (Either RemoteError ()) -> IO ()
    publishErrors publishErr action =
      action >>= \case
        Right _ -> pure ()
        Left err -> do
          logErr sessionLogger $ show err
          publishErr err

{- | Runs indefinitely as long as the `TMVar` is filled every `timeLimit` seconds
 Intended to be used with 'race'
-}
watchdog :: NominalDiffTime -> TMVar () -> IO ()
watchdog timeLimit var = loop
  where
    uSecs = floor $ timeLimit * 1000000
    loop =
      timeout uSecs (atomically (takeTMVar var))
        `whenJustM` const loop

-- | Passes chunks of data from a gRPC stream onto MQTT
streamReader ::
  forall response clientcall.
  (Message response) =>
  (forall r. (Message r) => r -> IO ()) ->
  clientcall ->
  HL.MetadataMap ->
  IO (Either GRPCIOError (Maybe response)) ->
  IO ()
streamReader publish _cc initMetadata recv = do
  publish $ fromMetadataMap initMetadata
  readLoop
  where
    readLoop =
      recv >>= \case
        Left err -> publish $ wrapResponse @response (ClientErrorResponse $ ClientIOError err)
        Right chunk -> do
          publish $ wrapStreamChunk chunk
          when (isJust chunk) readLoop

-- | Reads chunks from MQTT and send them on to the gRPC stream
streamSend :: forall request. MaybeT IO request -> StreamSend request -> IO ()
streamSend readChunk send = void $ runMaybeT loop
  where
    loop = do
      chunk <- readChunk
      _ <- liftIO $ send chunk
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
