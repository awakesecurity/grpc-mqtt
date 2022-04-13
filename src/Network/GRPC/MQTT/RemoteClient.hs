-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.

-- |
module Network.GRPC.MQTT.RemoteClient
  ( runRemoteClient,
  )
where

---------------------------------------------------------------------------------

import Control.Exception (bracket)
import Control.Monad.Except (throwError)

import Data.List (stripPrefix)
import Data.HashMap.Strict qualified as HashMap

import Network.GRPC.HighLevel.Client
  ( ClientError (ClientErrorNoParse, ClientIOError),
    ClientResult (ClientNormalResponse)
  , GRPCMethodType (Normal),
    StreamSend,
    StreamRecv,
    MetadataMap,
    WritesDone,
  )
import Network.GRPC.LowLevel (GRPCIOError)

import Network.MQTT.Client
  ( MessageCallback (SimpleCallback),
    MQTTClient,
    normalDisconnect,
    waitForClient,
  )
import Network.MQTT.Topic (Filter, Topic (unTopic), toFilter, split)

import Proto3.Suite
  ( Enumerated (Enumerated),
    Message,
    encodeMessage,
    fromByteString,
    toLazyByteString
  )
import Proto3.Wire.Encode qualified as Wire.Encode
import Proto3.Wire.Decode qualified as Wire.Decode

import UnliftIO (TChan, cancel, concurrently_, readTChan, writeTChan)
import UnliftIO.Exception (handle, handleAny)

---------------------------------------------------------------------------------

import Network.GRPC.HighLevel.Extra (wireEncodeMetadataMap)

import Network.GRPC.MQTT (MQTTException (MQTTException))
import Network.GRPC.MQTT.Core (Config (..), connectMQTT, subscribeOrThrow)
import Network.GRPC.MQTT.Logging
  ( Logger (log),
    logDebug,
    logErr,
    logInfo,
    logWarn
  )
import Network.GRPC.MQTT.RemoteClient.Handler
import Network.GRPC.MQTT.RemoteClient.Session
  ( Session (Session, sessHandlerThread, sessHeartbeatSem, sessRequestChan),
    SessionCtx (..),
    SessionManager,
    SessionMap,
    lookupSessionMap,
    newSession,
    newSessionMap,
    runSessionManager,
  )
import Network.GRPC.MQTT.Sequenced

import Network.GRPC.MQTT.Request (Request (..))
import Network.GRPC.MQTT.Request qualified as Request

import Network.GRPC.MQTT.Response.BiDiStreaming qualified as Response.BiDiStreaming
import Network.GRPC.MQTT.Response.ClientStreaming qualified as Response.ClientStreaming
import Network.GRPC.MQTT.Response.Normal qualified as Response.Normal
import Network.GRPC.MQTT.Response.ServerStreaming qualified as Response.ServerStreaming

import Network.GRPC.MQTT.Types (Batched (..), ClientHandler (..), MethodMap)
import Network.GRPC.MQTT.Wrap (getWrapT, parseErrorToRCE)
import Network.GRPC.MQTT.Wrapping (remoteError, toRemoteError)

import Proto.Mqtt
  ( AuxControl (AuxControlAlive, AuxControlTerminate),
    AuxControlMessage (AuxControlMessage),
    RemoteError,
  )

---------------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
runRemoteClient ::
  Logger ->
  Config ->
  Topic ->
  MethodMap ->
  IO ()
runRemoteClient logger config baseTopic methods = do
  sharedSessionMap <- newSessionMap
  let gatewayCallback :: MessageCallback
      gatewayCallback =
        simpleGatewayCallback
          logger
          config
          baseTopic
          methods
          sharedSessionMap

      cfgGateway :: Config
      cfgGateway = config {_msgCB = gatewayCallback }
   in bracket
        (connectMQTT cfgGateway)
        normalDisconnect
        (handleRemoteClient logger baseTopic)

-- | TODO
--
-- @since 1.0.0
handleRemoteClient :: Logger -> Topic -> MQTTClient -> IO ()
handleRemoteClient logger baseTopic gatewayClient = do
  handle (logException "MQTT client connection") $ do
    subscribeOrThrow gatewayClient [requestFilter, controlFilter]
    waitForClient gatewayClient

    logInfo logger "MQTT client connection terminated normally"
  where
    baseFilter :: Filter
    baseFilter = toFilter baseTopic

    requestFilter :: Filter
    requestFilter = baseFilter <> "grpc" <> "request" <> "+" <> "+" <> "+"

    controlFilter :: Filter
    controlFilter = baseFilter <> "grpc" <> "session" <> "+" <> "control"

    logException :: Text -> SomeException -> IO ()
    logException name e =
      let logmsg :: Text
          logmsg = name <> " terminated with exception: " <> toText (displayException e)
       in logErr logger logmsg

-- | Handles AuxControl signals from the "/control" topic
controlMsgHandler :: Logger -> Session -> LByteString -> IO ()
controlMsgHandler logger session mqttMessage = do
  case fromByteString (toStrict mqttMessage) of
    Right (AuxControlMessage (Enumerated (Right AuxControlTerminate))) -> do
      -- logInfo logger "Received terminate message"
      cancel $ sessHandlerThread session
    Right (AuxControlMessage (Enumerated (Right AuxControlAlive))) -> do
      -- logDebug logger "Received heartbeat message"
      void . atomically $ tryPutTMVar (sessHeartbeatSem session) ()
    Right ctrl -> do
      -- logWarn logger $ "Received unknown control message: " <> show ctrl
      pure ()
    Left err -> do
      -- logErr logger $ "Failed to parse control message: " <> show err
      pure ()

-- | TODO
--
-- @since 1.0.0
simpleGatewayCallback ::
  Logger ->
  Config ->
  Topic ->
  MethodMap ->
  SessionMap ->
  MessageCallback
simpleGatewayCallback logger config baseTopic methods sharedSessionMap =
  SimpleCallback \client topic msg _ -> do
    logInfo logger $ "Remote Client received request at topic: " <> unTopic topic
    logInfo logger $ "Remote Client message recieved: " <> show msg

    handleAny (logException "gatewayHandler") do
      case stripPrefix (split baseTopic) (split topic) of
        Nothing -> do
          bug $ MQTTException "Base topic mismatch"
          --
        Just ["grpc", "request", sessionId, service, method] -> do
          withSessionIO client sessionId service method \isNewSession session -> do
            logInfo logger "Remote Client shared message: "
            atomically (writeTChan (sessRequestChan session) msg)
            --
          --
        Just ["grpc", "session", sessionId, "control"] -> do
          let taggedLog msg = log logger $ "[" <> unTopic sessionId <> "] " <> msg
          let taggedLogger = logger{log = taggedLog}
          lookupSessionMap (unTopic sessionId) sharedSessionMap >>= \case
            Nothing -> logInfo taggedLogger "Received control message for non-existant session"
            Just session -> do
              controlMsgHandler taggedLogger session msg
          --
        _ -> do
          logErr logger $ "Failed to parse topic: " <> unTopic topic
  where

    logException :: Text -> SomeException -> IO ()
    logException name e =
      let logmsg :: Text
          logmsg = name <> " terminated with exception: " <> toText (displayException e)
       in logErr logger logmsg

    withSessionIO ::
      MQTTClient ->
      Topic ->
      Topic ->
      Topic ->
      (Bool -> Session -> SessionManager ()) ->
      IO ()
    withSessionIO client sessionId serviceTopic methodTopic k = do
      sessionM <- lookupSessionMap (unTopic sessionId) sharedSessionMap
      let taggedLog :: Text -> IO ()
          taggedLog msg = log logger $ "[" <> unTopic sessionId <> "] " <> msg

          sessionCtx :: SessionCtx
          sessionCtx =
            SessionCtx
              { sessCtxLogger = logger{log = taggedLog}
              , sessCtxSessionMap = sharedSessionMap
              , sessCtxClient = client
              , sessCtxMethodMap = methods
              , sessCtxBaseTopic = baseTopic
              , sessCtxSessionId = sessionId
              , sessCtxMaxMsgSize = fromIntegral $ mqttMsgSizeLimit config
              , sessCtxGrpcMethod = encodeUtf8 ("/" <> unTopic serviceTopic <> "/" <> unTopic methodTopic)
              }
       in case sessionM of
            Just session -> runSessionManager (k False session) sessionCtx $> ()
            Nothing -> runSessionManager (newSession (k True)) sessionCtx $> ()

-- | TODO
--
-- @since 1.0.0
sessionHandleRequest :: Session -> SessionManager ()
sessionHandleRequest session = do
  methods <- asks sessCtxMethodMap
  method <- asks sessCtxGrpcMethod

  case HashMap.lookup method methods of
    Nothing  -> do
      sessionId <- asks sessCtxSessionId
      let errmsg :: LText
          errmsg = "Failed to find gRPC client for: " <> toLazy (unTopic sessionId)
       in sessionHandleRemoteError (remoteError errmsg)
    Just hdl -> do
      bytes <- liftIO (atomically (readTChan (sessRequestChan session)))
      case Wire.Decode.parse Request.wireUnwrapRequest (toStrict bytes) of
        Left perr -> do
          liftIO $ print ("remote client parse error!")
          sessionHandleRemoteError (parseErrorToRCE perr)
          pure ()
        Right rqt -> do
          dispatchHandler rqt hdl
  where
    dispatchHandler :: Request ByteString -> ClientHandler -> SessionManager ()
    dispatchHandler Request {..} (ClientNormalHandler handler) = do
      client <- asks sessCtxClient
      topic <- sessionResponseTopic
      result <- liftIO $ handler rqtMessage rqtTimeout rqtMetadata

      let encoded :: Either ClientError LByteString
          encoded =
            Response.Normal.fromClientNormalResult result
              <&> Response.Normal.wireEncodeNormalResponse
              <&> Wire.Encode.toLazyByteString
       in case encoded of
            Left err -> sessionHandleClientError err
            Right payload -> liftIO (publishNormal client topic payload)
      --
    dispatchHandler Request {..} (ClientClientStreamHandler handler) = do
      client <- asks sessCtxClient
      topic <- sessionResponseTopic

      reader <- mkStreamRead =<< liftIO (mkPacketizedRead (sessRequestChan session))
      result <- liftIO (handler rqtTimeout rqtMetadata (streamSender reader))

      let encoded :: Either ClientError LByteString
          encoded =
            Response.ClientStreaming.fromClientStreamingResult result
              <&> Response.ClientStreaming.wireEncodeClientStreamingResponse
              <&> Wire.Encode.toLazyByteString
       in case encoded of
            Left err -> do
              liftIO $ print ("remote client response error!")
              sessionHandleClientError err
            Right payload -> liftIO (publishNormal client topic payload)
    dispatchHandler Request {..} (ClientServerStreamHandler batch handler) = do
      msgLim <- asks sessCtxMaxMsgSize
      client <- asks sessCtxClient
      topic <- sessionResponseTopic

      let publish = publishNormal client topic
      let reader  = streamReader (publish . toLazy) msgLim batch
      result <- liftIO (handler rqtMessage rqtTimeout rqtMetadata (const reader))

      let encoded :: Either ClientError LByteString
          encoded =
            Response.ServerStreaming.fromServerStreamingResult result
              <&> Response.ServerStreaming.wireEncodeServerStreamingResponse
              <&> Wire.Encode.toLazyByteString
       in case encoded of
            Left err -> do
              liftIO $ print ("remote client response error!")
              sessionHandleClientError err
            Right payload -> liftIO (publishNormal client topic payload)
    dispatchHandler Request {..} (ClientBiDiStreamHandler batch handler) = do
      topic <- sessionResponseTopic
      msgLim <- asks sessCtxMaxMsgSize
      client <- asks sessCtxClient
      reader <- mkStreamRead =<< liftIO (mkPacketizedRead (sessRequestChan session))

      let publish = publishNormal client topic
      let channel = bidiHandler reader (publish . toLazy) msgLim batch
      result <- liftIO (handler rqtTimeout rqtMetadata (const channel))

      let encoded :: Either ClientError LByteString
          encoded =
            Response.BiDiStreaming.fromBiDiStreamingResult result
              <&> Response.BiDiStreaming.wireEncodeBiDiStreamingResponse
              <&> Wire.Encode.toLazyByteString
       in case encoded of
            Left err -> do
              liftIO $ print ("remote client response error!")
              sessionHandleClientError err
            Right payload -> liftIO (publishNormal client topic payload)

-- | Passes chunks of data from a gRPC stream onto MQTT
--
-- @since 1.0.0
streamReader ::
  Message rsp =>
  (ByteString -> IO ()) ->
  Int ->
  Batched ->
  MetadataMap ->
  StreamRecv rsp ->
  IO ()
streamReader publish maxMsgSize useBatch initMetadata recv = do
  PublishToStream pubStream pubDone <- publishStream maxMsgSize useBatch publish

  let readLoop :: IO ()
      readLoop =
        recv >>= \case
          Left err -> undefined -- publish $ wrapResponse @response (ClientErrorResponse $ ClientIOError err)
          Right Nothing -> pubDone
          Right (Just rsp) ->
            let rspPayload :: ByteString
                rspPayload = toStrict (toLazyByteString rsp)
             in pubStream rspPayload >> readLoop

  let metadataEncoded :: ByteString
      metadataEncoded = toStrict (Wire.Encode.toLazyByteString (wireEncodeMetadataMap 1 initMetadata))
   in publish metadataEncoded -- encode wire

  readLoop

-- | TODO
--
-- @since 1.0.0
streamSender :: ExceptT RemoteError IO (Maybe rqt) -> StreamSend rqt -> IO ()
streamSender readChunk send = void $ runExceptT loop
  where
    -- TODO: handle any errors in read/send
    loop :: ExceptT RemoteError IO ()
    loop =
      readChunk >>= \case
        Nothing -> return ()
        Just chunk -> do
          void $ liftIO $ send chunk
          loop

-- | TODO
--
-- @since 1.0.0
bidiHandler ::
  Message rsp =>
  ExceptT RemoteError IO (Maybe rqt) ->
  (ByteString -> IO ()) ->
  Int ->
  Batched ->
  MetadataMap ->
  StreamRecv rsp ->
  StreamSend rqt ->
  WritesDone ->
  IO ()
bidiHandler readChunk publish maxMsgSize useBatch initMetadata recv send writesDone = do
  concurrently_
    (streamSender readChunk send >> writesDone)
    (streamReader publish maxMsgSize useBatch initMetadata recv)

-- | TODO
--
-- @since 1.0.0
sessionHandleParseError :: Wire.Decode.ParseError -> SessionManager ()
sessionHandleParseError err = sessionHandleRemoteError (parseErrorToRCE err)

-- | TODO
--
-- @since 1.0.0
sessionHandleGRPCIOError :: GRPCIOError -> SessionManager ()
sessionHandleGRPCIOError err = sessionHandleClientError (ClientIOError err)

-- | TODO
--
-- @since 1.0.0
sessionHandleClientError :: ClientError -> SessionManager ()
sessionHandleClientError err = sessionHandleRemoteError (toRemoteError err)

-- | TODO
--
-- @since 1.0.0
sessionHandleRemoteError :: RemoteError -> SessionManager ()
sessionHandleRemoteError err = do
  client <- asks sessCtxClient
  topic <- sessionResponseTopic
  liftIO (publishNormal client topic (toLazyByteString err))

-- | TODO
--
-- @since 1.0.0
sessionResponseTopic :: SessionManager Topic
sessionResponseTopic = do
  baseTopic <- asks sessCtxBaseTopic
  idTopic <- asks sessCtxSessionId
  pure (baseTopic <> "grpc" <> "session" <> idTopic)
