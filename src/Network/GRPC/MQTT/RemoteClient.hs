{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.

-- | TODO
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.RemoteClient
  ( runRemoteClient,
    runRemoteClientWithConnect,
  )
where

---------------------------------------------------------------------------------

import Control.Concurrent.Async qualified as Async

import Control.Concurrent.STM.TChan (writeTChan)

import Control.Exception (bracket)
import Control.Exception.Safe (handleAny)

import Control.Monad.Except (withExceptT)

import Data.List (stripPrefix)
import Data.Text qualified as Text

import Network.GRPC.HighLevel
  ( MetadataMap,
    StreamRecv,
    StreamSend,
  )
import Network.GRPC.HighLevel.Client
  ( ClientError (ClientIOError),
    ClientResult (ClientErrorResponse),
    WritesDone,
  )

import Network.MQTT.Topic (Filter, Topic)
import Network.MQTT.Topic qualified as Topic

import Proto3.Suite (Enumerated (Enumerated), Message)
import Proto3.Suite qualified as Proto3

import Proto3.Wire.Decode qualified as Decode

import Relude hiding (reader)

---------------------------------------------------------------------------------

import Control.Concurrent.TMap (TMap)
import Control.Concurrent.TMap qualified as TMap

import Network.GRPC.HighLevel.Extra (wireEncodeMetadataMap)

import Network.GRPC.MQTT.Core
  ( MQTTGRPCConfig (mqttMsgSizeLimit, _msgCB),
    connectMQTT,
    subscribeOrThrow,
  )
import Network.GRPC.MQTT.Logging (Logger)
import Network.GRPC.MQTT.Logging qualified as Logger
import Network.GRPC.MQTT.Message.Packet (packetReader)
import Network.GRPC.MQTT.Message.Request (Request (Request), wireUnwrapRequest)
import Network.GRPC.MQTT.RemoteClient.Session
import Network.GRPC.MQTT.RemoteClient.Session qualified as Session
import Network.GRPC.MQTT.Sequenced
  ( PublishToStream (..),
    mkPacketizedPublish,
    mkStreamPublish,
    mkStreamRead,
  )
import Network.GRPC.MQTT.Topic (makeControlFilter, makeRequestFilter)
import Network.GRPC.MQTT.Types
  ( Batched,
    ClientHandler (..),
    MethodMap,
  )
import Network.GRPC.MQTT.Wrapping
  ( fromLazyByteString,
    parseErrorToRCE,
    wrapResponse,
  )
import Network.MQTT.Client
  ( MQTTClient,
    MessageCallback (SimpleCallback),
    normalDisconnect,
    waitForClient,
  )

import Proto.Mqtt
  ( AuxControl (AuxControlAlive, AuxControlTerminate),
    AuxControlMessage (AuxControlMessage),
    RemoteError,
  )
import Proto.Mqtt qualified as Proto

---------------------------------------------------------------------------------

runRemoteClient :: Logger -> MQTTGRPCConfig -> Topic -> MethodMap -> IO ()
runRemoteClient = runRemoteClientWithConnect connectMQTT

runRemoteClientWithConnect ::
  (MQTTGRPCConfig -> IO MQTTClient) ->
  Logger ->
  MQTTGRPCConfig ->
  Topic ->
  MethodMap ->
  IO ()
runRemoteClientWithConnect onConnect logger cfg baseTopic methods = do
  sessions <- TMap.emptyIO
  handleConnect sessions \client -> do
    subRemoteClient client baseTopic
    waitForClient client
  where
    handleConnect :: TMap Topic SessionHandle -> (MQTTClient -> IO ()) -> IO ()
    handleConnect sessions =
      let cfgGateway :: MQTTGRPCConfig
          cfgGateway = cfg{_msgCB = handleGateway sessions}
       in bracket (onConnect cfgGateway) normalDisconnect

    handleGateway :: TMap Topic SessionHandle -> MessageCallback
    handleGateway sessions =
      SimpleCallback \client topic msg _ -> do
        handleAny handleError do
          case fromRqtTopic baseTopic topic of
            Nothing -> case stripPrefix (Topic.split baseTopic) (Topic.split topic) of
              Just ["grpc", "session", sessionId, "control"] -> do
                sessionHandle <- atomically (TMap.lookup sessionId sessions)
                case sessionHandle of
                  Nothing ->
                    let logmsg :: Text
                        logmsg = "Recieved control for non-existent session: " <> Topic.unTopic sessionId
                     in Logger.logErr logger logmsg
                  Just handle -> do
                    handleControlMessage logger handle msg
              _ ->
                -- TODO: FIXME: handle parse errors with a RemoteError response along
                -- with the following log message.
                let logmsg :: Text
                    logmsg = "Failed to parse topic: " <> Topic.unTopic topic
                 in Logger.logErr logger logmsg
            Just topics ->
              when (topicBase topics == baseTopic) do
                let sessionKey = topicSid topics
                let msglim = mqttMsgSizeLimit cfg
                let config = SessionConfig client sessions logger topics msglim methods

                sessionHandle <- atomically (TMap.lookup sessionKey sessions)

                let session :: Session ()
                    session = case sessionHandle of
                      Just handle -> liftIO do
                        atomically (writeTChan (hdlRqtChan handle) msg)
                      Nothing -> withSession \handle -> liftIO do
                        atomically (writeTChan (hdlRqtChan handle) msg)
                        handleNewSession config handle
                 in runSessionIO session config

    handleError :: SomeException -> IO ()
    handleError err = do
      let prefix = "Network.GRPC.MQTT.RemoteClient.runRemoteClient: "
      let errmsg = "caught exception: " ++ displayException err
      Logger.logErr logger (Text.pack (prefix ++ errmsg))

subRemoteClient :: MQTTClient -> Topic -> IO ()
subRemoteClient client baseTopic = do
  let rqts :: Filter = makeRequestFilter baseTopic
      ctrl :: Filter = makeControlFilter baseTopic
   in subscribeOrThrow client [rqts, ctrl]

---------------------------------------------------------------------------------

handleNewSession :: SessionConfig -> SessionHandle -> IO ()
handleNewSession config handle = handleWithHeartbeat
  where
    handleWithHeartbeat :: IO ()
    handleWithHeartbeat = Async.race_ runSession runHeartbeat

    runSession :: IO ()
    runSession = runSessionIO (handleRequest handle) config

    runHeartbeat :: IO ()
    runHeartbeat = do
      let period'sec = 1 + defaultWatchdogPeriodSec
      newWatchdogIO period'sec (hdlHeartbeat handle)
      Logger.logWarn (cfgLogger config) "Watchdog timed out"

pattern AuxMessageAlive :: AuxControlMessage
pattern AuxMessageAlive = AuxControlMessage (Enumerated (Right AuxControlAlive))

pattern AuxMessageTerminate :: AuxControlMessage
pattern AuxMessageTerminate = AuxControlMessage (Enumerated (Right AuxControlTerminate))

-- | Handles AuxControl signals from the "/control" topic
handleControlMessage :: Logger -> SessionHandle -> LByteString -> IO ()
handleControlMessage logger handle msg = do
  case fromLazyByteString msg of
    Right AuxMessageTerminate -> do
      Logger.logInfo logger "Received terminate message"
      Async.cancel (hdlThread handle)
    Right AuxMessageAlive -> do
      Logger.logDebug logger "Received heartbeat message"
      atomically do
        _ <- tryPutTMVar (hdlHeartbeat handle) ()
        pure ()
    Right ctrl ->
      Logger.logWarn logger $ "Received unknown control message: " <> show ctrl
    Left err ->
      Logger.logErr logger $ "Failed to parse control message: " <> show err

-- | TODO
--
-- @since 0.1.0.0
handleRequest :: SessionHandle -> Session ()
handleRequest handle = do
  request <- liftIO (runExceptT (withExceptT parseErrorToRCE (packetReader (hdlRqtChan handle))))

  case decode =<< request of
    Left err -> do
      let errmsg :: Text
          errmsg = "proto3-wire parse error (" <> show err <> ")"
       in Session.logError 'handleRequest errmsg
      pubRemoteError err
    Right (Request rawmsg timeout metadata) -> do
      logger <- asks cfgLogger
      Logger.logDebug logger $
        unlines
          [ "Wrapped request data: "
          , "  Timeout: " <> show timeout
          , "  Metadata: " <> show metadata
          ]

      dispatchClientHandler \case
        ClientUnaryHandler k -> do
          result <- liftIO (k rawmsg timeout metadata)
          rspPublish (wrapResponse result)
        ClientClientStreamHandler k -> do
          reader <- mkStreamRead (withExceptT parseErrorToRCE (packetReader (hdlRqtChan handle)))
          sender <- clientStreamSender reader
          result <- liftIO (k timeout metadata sender)
          rspPublish (wrapResponse result)
        ClientServerStreamHandler batch k -> do
          config <- ask
          topic <- askResponseTopic
          let reader cc ms recv = runSessionIO (serverStreamReader (publishPackets topic) batch cc ms recv) config
          result <- liftIO (k rawmsg timeout metadata reader)
          rspPublish (wrapResponse result)
        ClientBiDiStreamHandler batch k -> do
          config <- ask
          readStream <- mkStreamRead (withExceptT parseErrorToRCE (packetReader (hdlRqtChan handle)))
          sender <- fmap publishPackets askResponseTopic
          let reader = streamReader readStream
          let handler cc ms recv send done = runSessionIO (bidiHandler (lift reader) sender batch cc ms recv send done) config
          rsp <- liftIO (k timeout metadata handler)
          rspPublish (wrapResponse rsp)
  where
    rspPublish :: Message a => a -> Session ()
    rspPublish rsp = do
      topic <- askResponseTopic
      let encoded :: LByteString
          encoded = Proto3.toLazyByteString rsp
       in publishPackets topic encoded

    pubRemoteError :: RemoteError -> Session ()
    pubRemoteError err = do
      topic <- askResponseTopic
      publishRemoteError topic err

    decode :: LByteString -> Either RemoteError (Request ByteString)
    decode msg =
      let decoded :: Either Decode.ParseError (Request ByteString)
          decoded = wireUnwrapRequest (toStrict msg)
       in case decoded of
            Left err -> Left (parseErrorToRCE err)
            Right xs -> Right xs

-- | TODO
--
-- @since 0.1.0.0
dispatchClientHandler :: (ClientHandler -> Session ()) -> Session ()
dispatchClientHandler k = maybe onError k =<< askMethod
  where
    -- FIXME: The error message's details are lost in transit to the client.
    onError :: Session ()
    onError = do
      rspTopic <- askResponseTopic
      mthTopic <- askMethodTopic
      -- When a non-existent 'ClientHandler' is requested, this remote error
      -- is sent bad reporting:
      --   1. That gRPC a call error occured.
      --   2. The name of the bad call that was requested.
      --   3. A gRPC status code 12 for an "unimplemented" call as per gRPC status
      --      code docs: https://grpc.github.io/grpc/core/md_doc_statuscodes.html
      let etype = Proto3.Enumerated (Right Proto.RErrorIOGRPCCallError)
          ecall = fromStrict ("/" <> Topic.unTopic mthTopic)
          extra = Just (Proto.RemoteErrorExtraStatusCode 12)
       in publishRemoteError rspTopic (Proto.RemoteError etype ecall extra)

---------------------------------------------------------------------------------

publishPackets :: Topic -> LByteString -> Session ()
publishPackets topic msg = do
  client <- asks cfgClient
  msglim <- asks (fromIntegral . cfgMsgSize)
  mkPacketizedPublish client msglim topic msg

-- | Encodes the given 'RemoteError', and publishes it to the topic provided.
--
-- @since 0.1.0.0
publishRemoteError :: Topic -> RemoteError -> Session ()
publishRemoteError topic err = do
  logger <- asks cfgLogger
  let prefix = "Network.GRPC.MQTT.RemoteClient.publishRemoteError: "
      errmsg = "publishing remote error: " <> show err
   in Logger.logErr logger (prefix <> errmsg)

  let errmsg :: Proto.WrappedResponse
      errmsg = Proto.WrappedResponse $ Just $ Proto.WrappedResponseOrErrorError $ err
   in publishPackets topic (Proto3.toLazyByteString errmsg)

---------------------------------------------------------------------------------

bidiHandler ::
  Message rsp =>
  ExceptT RemoteError Session (Maybe rqt) ->
  (LByteString -> Session ()) ->
  Batched ->
  clientcall ->
  MetadataMap ->
  StreamRecv rsp ->
  StreamSend rqt ->
  WritesDone ->
  Session ()
bidiHandler reader sender batch cc metadata srecv ssend done = do
  config <- ask
  let sreader = serverStreamReader sender batch cc metadata srecv
  ssender <- serverStreamSender reader

  liftIO do
    Async.concurrently_
      (ssender ssend >> done)
      (runSessionIO sreader config)

---------------------------------------------------------------------------------

streamReader :: ExceptT RemoteError IO (Maybe a) -> Session (Maybe a)
streamReader reader = do
  result <- liftIO (runExceptT reader)
  case result of
    Left err -> onError err
    Right xs -> pure xs
  where
    onError :: RemoteError -> Session (Maybe a)
    onError err = do
      topic <- askResponseTopic
      publishRemoteError topic err
      pure Nothing

serverStreamReader ::
  forall a clientcall.
  Message a =>
  (LByteString -> Session ()) ->
  Batched ->
  clientcall ->
  MetadataMap ->
  StreamRecv a ->
  Session ()
serverStreamReader publish batch _ initMetadata recv = do
  publishIO <- asks \config x -> runSessionIO (publish x) config
  msglimit <- asks (fromIntegral @_ . cfgMsgSize)
  PublishToStream{publishToStream, publishToStreamCompleted} <-
    mkStreamPublish msglimit batch \x -> do
      (publishIO . Proto3.toLazyByteString) x

  let readLoop :: IO ()
      readLoop = do
        recieved <- recv
        case recieved of
          Left err -> do
            publishIO $ Proto3.toLazyByteString $ wrapResponse @a (ClientErrorResponse $ ClientIOError err)
          Right (Just rsp) -> do
            publishToStream rsp
            readLoop
          Right Nothing ->
            publishToStreamCompleted

  liftIO do
    publishIO $ (wireEncodeMetadataMap initMetadata)
    readLoop

---------------------------------------------------------------------------------

clientStreamSender ::
  forall a.
  ExceptT RemoteError IO (Maybe a) ->
  Session (StreamSend a -> IO ())
clientStreamSender source = do
  config <- ask
  pure \send ->
    let reader :: Session (Maybe a)
        reader = streamReader source
     in runSessionIO (loop send reader) config
  where
    loop :: StreamSend a -> Session (Maybe a) -> Session ()
    loop sender reader = do
      chunk <- reader
      case chunk of
        Nothing -> pure ()
        Just xs -> do
          _ <- liftIO (sender xs)
          loop sender reader

serverStreamSender ::
  forall a.
  ExceptT RemoteError Session (Maybe a) ->
  Session (StreamSend a -> IO ())
serverStreamSender reader = asks loop
  where
    loop :: SessionConfig -> StreamSend a -> IO ()
    loop config sender = do
      chunk <- runSessionIO (runExceptT reader) config
      case chunk of
        Left err -> do
          runSessionIO (onError err) config
        Right Nothing -> return ()
        Right (Just x) -> do
          _ <- liftIO (sender x)
          loop config sender

    onError :: RemoteError -> Session ()
    onError err = do
      rspTopic <- askResponseTopic
      publishRemoteError rspTopic err
