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
    toFilter,
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
  ( ClientHandler (ClientClientStreamHandler, ClientServerStreamHandler, ClientUnaryHandler),
    MethodMap,
    SessionId,
  )
import Network.GRPC.MQTT.Wrapping
  ( parseErrorToRCE,
    rceMQTTError,
    toMetadataMap,
    unwrapStreamChunk,
    wrapClientStreamResponse,
    wrapStreamChunk,
    wrapStreamInitMetadata,
    wrapStreamResponse,
    wrapUnaryResponse,
  )

import Control.Exception (bracket)
import Control.Monad.Except
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
  )
import Proto.Mqtt
  ( AuxControl (AuxControlAlive, AuxControlTerminate),
    AuxControlMessage (AuxControlMessage),
    RemoteClientError (..),
    WrappedMQTTRequest (WrappedMQTTRequest),
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
  , requestChan :: TChan LByteString
  }

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
              heartbeatMon
              (requestHandler args reqChan)
          heartbeatMon :: IO ()
          heartbeatMon = do
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
  publishResponse <- mkPacketizedPublish client maxMsgSize responseTopic

  publishErrors publishResponse . runExceptT $ do
    clientHandler <-
      lookup grpcMethod methodMap
        `whenNothing` throwError (rceMQTTError $ "Failed to find gRPC client for: " <> decodeUtf8 grpcMethod)

    readRequest <- liftIO $ mkPacketizedRead reqChan
    mqttMessage <- readRequest

    (WrappedMQTTRequest timeLimit reqMetadata payload) <- withExceptT parseErrorToRCE $ hoistEither (fromByteString (toStrict mqttMessage))

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
        publishResponse $ wrapUnaryResponse response

      -- Run Client Streaming Request
      ClientClientStreamHandler handler -> do
        let readStreamChunk :: (Message request) => MaybeT IO request
            readStreamChunk = do
              res <- exceptToMaybeT readRequest
              case unwrapStreamChunk res of
                Left _ -> empty
                Right c -> hoistMaybe c

        response <- handler (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata) (streamSend readStreamChunk)
        publishResponse $ wrapClientStreamResponse response

      -- Run Server Streaming Request
      ClientServerStreamHandler handler -> do
        response <- handler payload (fromIntegral timeLimit) (maybe mempty toMetadataMap reqMetadata) (streamReader publishResponse)
        publishResponse $ wrapStreamResponse response
  where
    publishErrors :: (LByteString -> IO ()) -> IO (Either RemoteClientError ()) -> IO ()
    publishErrors publishErr action =
      action >>= \case
        Right _ -> pure ()
        Left err -> do
          logErr sessionLogger $ show err
          publishErr $ toLazyByteString err

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
  (LByteString -> IO ()) ->
  clientcall ->
  HL.MetadataMap ->
  IO (Either GRPCIOError (Maybe response)) ->
  IO ()
streamReader publish _cc initMetadata recv = do
  publish $ wrapStreamInitMetadata initMetadata
  readLoop
  where
    readLoop =
      recv >>= \case
        Left err -> publish $ wrapStreamResponse @response (ClientErrorResponse $ ClientIOError err)
        Right chunk -> do
          publish $ wrapStreamChunk chunk
          when (isJust chunk) readLoop

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
