{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.

-- | gRPC-MQTT remote clients.
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.RemoteClient
  ( runRemoteClient,
    runRemoteClientWithConnect,
  )
where

---------------------------------------------------------------------------------

import Control.Concurrent.Async qualified as Async

import Control.Concurrent.STM.TQueue (TQueue, writeTQueue)

import Control.Exception (bracket, throwIO)
import Control.Exception.Safe (handleAny)

import Control.Monad.Except (MonadError, throwError)
import Control.Monad.IO.Unlift (withRunInIO)

import Data.List (stripPrefix)
import Data.Text qualified as Text
import Data.Traversable (for)

import Network.GRPC.LowLevel (GRPCIOError, StreamRecv, StreamSend)
import Network.GRPC.LowLevel.Op (WritesDone)

import Network.MQTT.Client
  ( MQTTClient,
    MessageCallback (SimpleCallback),
    QoS (QoS1),
    normalDisconnect,
    publishq,
    waitForClient,
  )
import Network.MQTT.Topic (Filter, Topic)
import Network.MQTT.Topic qualified as Topic

import Proto3.Suite qualified as Proto3

import Proto3.Wire.Decode qualified as Decode

import Relude hiding (reader)

import UnliftIO.Async (concurrently_)

---------------------------------------------------------------------------------

import Control.Concurrent.TMap (TMap)
import Control.Concurrent.TMap qualified as TMap

import Network.GRPC.HighLevel.Extra (wireEncodeMetadataMap)

import Network.GRPC.MQTT.Core
  ( MQTTGRPCConfig (mqttMsgSizeLimit, _msgCB),
    connectMQTT,
    heartbeatPeriodSeconds,
    mqttPublishRateLimit,
    subscribeOrThrow,
  )

import Network.GRPC.MQTT.Logging (Logger)
import Network.GRPC.MQTT.Logging qualified as Logger

import Network.GRPC.MQTT.Message qualified as Message
import Network.GRPC.MQTT.Message.AuxControl
  ( AuxControlMessage (AuxMessageAlive, AuxMessageTerminate),
  )
import Network.GRPC.MQTT.Message.Packet qualified as Packet
import Network.GRPC.MQTT.Message.Request qualified as Request
import Network.GRPC.MQTT.Message.Response qualified as Response
import Network.GRPC.MQTT.Message.Stream qualified as Stream

import Network.GRPC.MQTT.Option (ProtoOptions)

import Network.GRPC.MQTT.RemoteClient.Session
  ( Session,
    SessionConfig
      ( SessionConfig,
        cfgClient,
        cfgLogger,
        cfgMsgSize,
        cfgRateLimit
      ),
    SessionHandle (hdlHeartbeat, hdlRqtQueue, hdlThread),
    SessionTopic (topicBase, topicSid),
    askMethod,
    askMethodTopic,
    askResponseTopic,
    fromRqtTopic,
    newWatchdogIO,
    runSessionIO,
    withSession,
  )
import Network.GRPC.MQTT.RemoteClient.Session qualified as Session

import Network.GRPC.MQTT.Serial (WireDecodeOptions, WireEncodeOptions)
import Network.GRPC.MQTT.Serial qualified as Serial
import Network.GRPC.MQTT.Topic (makeControlFilter, makeRequestFilter)
import Network.GRPC.MQTT.Types (ClientHandler (..), MethodMap, RemoteResult)

import Network.GRPC.MQTT.Wrapping (parseErrorToRCE)
import Network.GRPC.MQTT.Wrapping qualified as Wrapping

import Proto.Mqtt (RemoteError)
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
                let rateLimit = mqttPublishRateLimit cfg
                let config = SessionConfig client sessions logger topics msglim rateLimit methods

                sessionHandle <- atomically (TMap.lookup sessionKey sessions)

                let session :: Session ()
                    session = case sessionHandle of
                      Just handle -> liftIO do
                        atomically (writeTQueue (hdlRqtQueue handle) (toStrict msg))
                      Nothing -> withSession \handle -> liftIO do
                        atomically (writeTQueue (hdlRqtQueue handle) (toStrict msg))
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
      let period'sec = 3 * heartbeatPeriodSeconds
      newWatchdogIO period'sec (hdlHeartbeat handle)
      Logger.logWarn (cfgLogger config) "Watchdog timed out"

-- | Handles AuxControl signals from the "/control" topic
handleControlMessage :: Logger -> SessionHandle -> LByteString -> IO ()
handleControlMessage logger handle msg =
  let result :: Either Decode.ParseError AuxControlMessage
      result = Proto3.fromByteString (toStrict msg)
   in case result of
        Right AuxMessageTerminate -> do
          Logger.logInfo logger "Received terminate message"
          Async.cancel (hdlThread handle)
        Right AuxMessageAlive -> do
          Logger.logDebug logger "Received heartbeat message"
          atomically do
            _ <- tryPutTMVar (hdlHeartbeat handle) ()
            pure ()
        Right unknown -> do
          Logger.logWarn logger $ "Received unknown control message" <> show unknown
        Left other -> do
          Logger.logErr logger $ "Failed to parse control message: " <> show other

-- | TODO
--
-- @since 0.1.0.0
handleRequest :: SessionHandle -> Session ()
handleRequest handle = do
  let queue = hdlRqtQueue handle
  runExceptT (Request.makeRequestReader queue) >>= \case
    Left err -> do
      Session.logError "wire parse error encountered parsing Request" (show err)
      publishRemoteError Serial.defaultEncodeOptions (Message.toRemoteError err)
    Right rqt@Request.Request{..} -> do
      let encodeOptions = Serial.makeRemoteEncodeOptions options
      let decodeOptions = Serial.makeClientDecodeOptions options

      Session.logDebug "handling client request" (show rqt)

      dispatchClientHandler \case
        ClientUnaryHandler k -> do
          result <- liftIO (k message timeout metadata)
          publishClientResponse encodeOptions result
        ClientClientStreamHandler k -> do
          result <- withRunInIO \runIO -> do
            let sender = makeClientStreamSender queue options
            k timeout metadata (runIO . sender)
          publishClientResponse encodeOptions result
        ClientServerStreamHandler k -> do
          result <- withRunInIO \runIO -> do
            k message timeout metadata \_ ms recv -> runIO do
              publishPackets (toStrict $ wireEncodeMetadataMap ms)
              makeServerStreamReader encodeOptions recv
          publishClientResponse encodeOptions result
        ClientBiDiStreamHandler k -> do
          result <- withRunInIO \runIO -> do
            k timeout metadata \_ getMetadata recv send done ->
              liftIO getMetadata >>= either throwIO \ms -> runIO do
                publishPackets (toStrict $ wireEncodeMetadataMap ms)
                let reader = makeServerStreamReader encodeOptions recv
                    sender = makeServerStreamSender queue encodeOptions decodeOptions send done
                 in concurrently_ sender reader
          publishClientResponse encodeOptions result

dispatchClientHandler :: (ClientHandler -> Session ()) -> Session ()
dispatchClientHandler k = do
  maybe onError k =<< askMethod
  where
    -- FIXME: The error message's details are lost in transit to the client.
    onError :: Session ()
    onError = do
      mthTopic <- askMethodTopic
      Session.logError "made request to unknown RPC" (Topic.unTopic mthTopic)
      -- When a non-existent 'ClientHandler' is requested, this remote error
      -- is sent bad reporting:
      --   1. That gRPC a call error occured.
      --   2. The name of the bad call that was requested.
      --   3. A gRPC status code 12 for an "unimplemented" call as per gRPC status
      --      code docs: https://grpc.github.io/grpc/core/md_doc_statuscodes.html
      let etype = Proto3.Enumerated (Right Proto.RErrorIOGRPCCallError)
          ecall = fromStrict ("/" <> Topic.unTopic mthTopic)
          extra = Just (Proto.RemoteErrorExtraStatusCode 12)
       in publishRemoteError
            Serial.defaultEncodeOptions
            (Proto.RemoteError etype ecall extra)

---------------------------------------------------------------------------------

publishClientResponse ::
  WireEncodeOptions ->
  RemoteResult s ->
  Session ()
publishClientResponse options result = do
  client <- asks cfgClient
  topic <- askResponseTopic
  packetSizeLimit <- asks cfgMsgSize
  rateLimit <- asks cfgRateLimit

  Session.logDebug "publishing response as packets to client" (Topic.unTopic topic)
  Session.logDebug "...with packet size" (show packetSizeLimit)

  Response.makeResponseSender client topic packetSizeLimit rateLimit options result

publishPackets :: ByteString -> Session ()
publishPackets message = do
  client <- asks cfgClient
  topic <- askResponseTopic
  packetSizeLimit <- asks cfgMsgSize
  rateLimit <- asks cfgRateLimit

  Session.logDebug "publishing message as packets" (show message)
  Session.logDebug "...to the response topic" (Topic.unTopic topic)

  let publish :: ByteString -> IO ()
      publish bytes = publishq client topic (fromStrict bytes) False QoS1 []
   in Packet.makePacketSender packetSizeLimit rateLimit (liftIO . publish) message

publishGRPCIOError :: WireEncodeOptions -> GRPCIOError -> Session ()
publishGRPCIOError options err =
  publishRemoteError options (Wrapping.toRemoteError err)

-- | Encodes the given 'RemoteError', and publishes it to the topic provided.
--
-- @since 0.1.0.0
publishRemoteError :: WireEncodeOptions -> RemoteError -> Session ()
publishRemoteError options err = do
  -- TODO: note why remote error cannot take encoding options
  let response = Proto.WrappedResponse $ Just $ Proto.WrappedResponseOrErrorError err
  client <- asks cfgClient
  topic <- askResponseTopic
  packetSizeLimit <- asks cfgMsgSize
  rateLimit <- asks cfgRateLimit

  Session.logError "publishing remote error as packets" (show response)
  Session.logError "...to the response topic" (Topic.unTopic topic)

  Response.makeErrorResponseSender client topic packetSizeLimit rateLimit options err

---------------------------------------------------------------------------------

makePacketReader ::
  TQueue ByteString ->
  Session (Either RemoteError ByteString)
makePacketReader channel = do
  result <- runExceptT (Packet.makePacketReader channel)
  case result of
    Left err -> do
      Session.logError "wire parse error encountered parsing Packet" (show err)
      pure (Left $ parseErrorToRCE err)
    Right bs -> do
      Session.logDebug "read packets to ByteString" (show bs)
      pure (Right bs)

handleStreamSend :: WireEncodeOptions -> StreamSend a -> a -> Session ()
handleStreamSend options send x = do
  result <- liftIO (send x)
  case result of
    Right () -> pure ()
    Left err -> do
      Session.logError "gRPC IO error encountered handling StreamSend" (show err)
      publishGRPCIOError options err

handleWritesDone :: WireEncodeOptions -> WritesDone -> Session ()
handleWritesDone options done =
  liftIO done >>= \case
    Right () -> pure ()
    Left err -> do
      Session.logError "gRPC IO error encountered handling WritesDone" (show err)
      publishGRPCIOError options err

---------------------------------------------------------------------------------

makeServerStreamSender ::
  TQueue ByteString ->
  WireEncodeOptions ->
  WireDecodeOptions ->
  StreamSend ByteString ->
  WritesDone ->
  Session ()
makeServerStreamSender queue encodeOptions decodeOptions sender done = do
  reader <- makeClientStreamReader @_ queue decodeOptions
  fix \loop -> do
    runExceptT reader >>= \case
      Left err -> do
        handleWritesDone encodeOptions done
        publishRemoteError encodeOptions err
      Right Nothing ->
        handleWritesDone encodeOptions done
      Right (Just x) -> do
        handleStreamSend encodeOptions sender x
        loop

makeServerStreamReader ::
  WireEncodeOptions ->
  StreamRecv ByteString ->
  Session ()
makeServerStreamReader options recv = do
  (send, done) <- makeStreamSender
  fix \loop ->
    liftIO recv >>= \case
      Left err -> do
        Session.logError "server stream reader: encountered error reading chunk" (show err)
        done
        publishGRPCIOError options err
      Right Nothing -> do
        Session.logDebug "server stream sender" "done"
        done
      Right (Just x) ->
        let message :: ByteString
            message = Message.mapEncodeOptions options x
         in send message >> loop
  where
    makeStreamSender :: Session (ByteString -> Session (), Session ())
    makeStreamSender = do
      client <- asks cfgClient
      topic <- askResponseTopic
      packetSizeLimit <- asks cfgMsgSize
      rateLimit <- asks cfgRateLimit
      Stream.makeStreamBatchSender packetSizeLimit rateLimit options \chunk -> do
        Session.logDebug "publish server stream chunk as bytes" (show chunk)
        liftIO (publishq client topic (fromStrict chunk) False QoS1 [])

---------------------------------------------------------------------------------

makeClientStreamReader ::
  (MonadError RemoteError m, MonadIO m) =>
  TQueue ByteString ->
  WireDecodeOptions ->
  Session (m (Maybe ByteString))
makeClientStreamReader queue options = do
  reader <- Stream.makeStreamReader queue options
  withRunInIO \runIO -> pure do
    result <- runExceptT reader
    case result of
      Left err -> do
        liftIO $ runIO do
          Session.logError "client stream reader: encountered error reading chunk" (show err)
        throwError err
      Right chunk -> do
        liftIO $ runIO do
          Session.logDebug "client stream reader: read chunk" (show chunk)
        for chunk \bytes -> do
          runExceptT (Message.mapDecodeOptions options bytes) >>= \case
            Left err -> throwError (Message.toRemoteError err)
            Right rx -> pure rx

makeClientStreamSender ::
  TQueue ByteString ->
  ProtoOptions ->
  StreamSend ByteString ->
  Session ()
makeClientStreamSender queue options sender = do
  let encodeOptions = Serial.makeRemoteEncodeOptions options
  let decodeOptions = Serial.makeRemoteDecodeOptions options
  reader <- makeClientStreamReader queue decodeOptions
  fix \loop ->
    runExceptT reader >>= \case
      Left err -> publishRemoteError encodeOptions err
      Right Nothing -> Session.logDebug "client stream sender" "done"
      Right (Just x) -> do
        Session.logDebug "client stream sender" "sending chunk"
        handleStreamSend encodeOptions sender x
        loop
