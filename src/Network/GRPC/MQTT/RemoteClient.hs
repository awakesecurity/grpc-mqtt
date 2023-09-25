{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      :  Network.GRPC.MQTT.RemoteClient
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- gRPC-MQTT remote clients.
--
-- @since 1.0.0
module Network.GRPC.MQTT.RemoteClient
  ( runRemoteClient,
    runRemoteClientWithConnect,
  )
where

---------------------------------------------------------------------------------

import Control.Concurrent.Async qualified as Async

import Control.Concurrent.OrderedTQueue
  ( Indexed (Indexed),
    OrderedTQueue,
    writeOrderedTQueue,
  )

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
    Property (PropUserProperty),
    normalDisconnect,
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
    Publisher,
    connectMQTT,
    heartbeatPeriodSeconds,
    mkIndexedPublish,
    mqttPublishRateLimit,
    subscribeOrThrow,
  )

import Network.GRPC.MQTT.Logging (RemoteClientLogger (..))
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
import Network.GRPC.MQTT.Topic (Topic (unTopic), makeControlFilter, makeRequestFilter)
import Network.GRPC.MQTT.Types (ClientHandler (..), MethodMap, RemoteResult (..))

import Network.GRPC.MQTT.Wrapping qualified as Wrapping

import Proto.Mqtt (RemoteError)
import Proto.Mqtt qualified as Proto

---------------------------------------------------------------------------------

runRemoteClient :: RemoteClientLogger -> MQTTGRPCConfig -> Topic -> MethodMap -> IO ()
runRemoteClient = runRemoteClientWithConnect connectMQTT

runRemoteClientWithConnect ::
  (MQTTGRPCConfig -> IO MQTTClient) ->
  RemoteClientLogger ->
  MQTTGRPCConfig ->
  Topic ->
  MethodMap ->
  IO ()
runRemoteClientWithConnect onConnect rcLogger@RemoteClientLogger{logger} cfg baseTopic methods = do
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
      SimpleCallback \client topic msg props -> do
        handleAny handleError do
          case fromRqtTopic baseTopic topic of
            Nothing -> case stripPrefix (Topic.split baseTopic) (Topic.split topic) of
              Just ["grpc", "session", sessionId, "control"] ->
                atomically (TMap.lookup sessionId sessions) >>= \case
                  Nothing ->
                    let logmsg :: Text
                        logmsg = "Recieved control for non-existent session: " <> Topic.unTopic sessionId
                     in Logger.logErr logger logmsg
                  Just sessionHandle -> do
                    handleControlMessage (Session.useSessionId sessionId rcLogger) sessionHandle msg
              _ ->
                -- TODO: FIXME: handle parse errors with a RemoteError response along
                -- with the following log message.
                let logmsg :: Text
                    logmsg = "Failed to parse topic: " <> Topic.unTopic topic
                 in Logger.logErr logger logmsg
            Just topics ->
              when (topicBase topics == baseTopic) do
                index <- case props of
                  [PropUserProperty "i" v] -> case readEither @Int32 (decodeUtf8 v) of
                    Right i -> pure i
                    Left e -> do
                      Logger.logErr logger ("Failed to decode index: " <> show e)
                      return 0
                  _ -> do
                    Logger.logDebug logger ("ahhh, bad properties - RC: " <> show props)
                    return 0
                let sessionKey = topicSid topics
                let msglim = mqttMsgSizeLimit cfg
                let rateLimit = mqttPublishRateLimit cfg
                let config = SessionConfig client sessions (Session.useSessionId sessionKey rcLogger) topics msglim rateLimit methods

                sessionHandle <- atomically (TMap.lookup sessionKey sessions)

                let session :: Session ()
                    session = case sessionHandle of
                      Just handle -> liftIO do
                        atomically (writeOrderedTQueue (hdlRqtQueue handle) (Indexed index (toStrict msg)))
                      Nothing -> withSession \handle -> liftIO do
                        atomically (writeOrderedTQueue (hdlRqtQueue handle) (Indexed index (toStrict msg)))
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
      Logger.logWarn (logger (cfgLogger config)) "Watchdog timed out"

-- | Handles AuxControl signals from the "/control" topic
handleControlMessage :: RemoteClientLogger -> SessionHandle -> LByteString -> IO ()
handleControlMessage RemoteClientLogger{logger} handle msg =
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
-- @since 1.0.0
handleRequest :: SessionHandle -> Session ()
handleRequest handle = do
  let queue = hdlRqtQueue handle
  publisher <- mkIndexedPublish
  runExceptT (Request.makeRequestReader queue) >>= \case
    Left err -> do
      Session.logError "wire parse error encountered parsing Request" (show err)
      publishRemoteError publisher Serial.defaultEncodeOptions (Message.toRemoteError err)
    Right request@Request.Request{..} -> do
      let encodeOptions = Serial.makeRemoteEncodeOptions options
      let decodeOptions = Serial.makeClientDecodeOptions options

      method <- askMethodTopic
      Session.logRequest (unTopic method) request

      dispatchClientHandler publisher \case
        ClientUnaryHandler k -> do
          result <- liftIO (k message timeout metadata)
          publishClientResponse publisher encodeOptions result
        ClientClientStreamHandler k -> do
          result <- withRunInIO \runIO -> do
            let sender = makeClientStreamSender publisher queue options
            k timeout metadata (runIO . sender)
          publishClientResponse publisher encodeOptions result
        ClientServerStreamHandler k -> do
          result <- withRunInIO \runIO -> do
            k message timeout metadata \_ ms recv -> runIO do
              publishPackets publisher (toStrict $ wireEncodeMetadataMap ms)
              makeServerStreamReader publisher encodeOptions recv
          publishClientResponse publisher encodeOptions result
        ClientBiDiStreamHandler k -> do
          result <- withRunInIO \runIO -> do
            k timeout metadata \_ getMetadata recv send done ->
              liftIO getMetadata >>= either throwIO \ms -> runIO do
                publishPackets publisher (toStrict $ wireEncodeMetadataMap ms)
                let reader = makeServerStreamReader publisher encodeOptions recv
                    sender = makeServerStreamSender publisher queue encodeOptions decodeOptions send done
                 in concurrently_ sender reader
          publishClientResponse publisher encodeOptions result

dispatchClientHandler :: Publisher -> (ClientHandler -> Session ()) -> Session ()
dispatchClientHandler publisher k = do
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
            publisher
            Serial.defaultEncodeOptions
            (Proto.RemoteError etype ecall extra)

---------------------------------------------------------------------------------

publishClientResponse ::
  Publisher ->
  WireEncodeOptions ->
  RemoteResult s ->
  Session ()
publishClientResponse publisher options result = do
  client <- asks cfgClient
  topic <- askResponseTopic
  packetSizeLimit <- asks cfgMsgSize
  rateLimit <- asks cfgRateLimit

  Session.logResponse result

  Response.makeResponseSender publisher client topic packetSizeLimit rateLimit options result

publishPackets :: Publisher -> ByteString -> Session ()
publishPackets publisher message = do
  client <- asks cfgClient
  topic <- askResponseTopic
  packetSizeLimit <- asks cfgMsgSize
  rateLimit <- asks cfgRateLimit

  Session.logDebug "publishing message as packets" (show message)

  let publish :: ByteString -> IO ()
      publish bytes = publisher client topic (fromStrict bytes)
   in Packet.makePacketSender packetSizeLimit rateLimit (liftIO . publish) message

publishGRPCIOError :: Publisher -> WireEncodeOptions -> GRPCIOError -> Session ()
publishGRPCIOError publisher options err =
  publishRemoteError publisher options (Wrapping.toRemoteError err)

-- | Encodes the given 'RemoteError', and publishes it to the topic provided.
--
-- @since 1.0.0
publishRemoteError :: Publisher -> WireEncodeOptions -> RemoteError -> Session ()
publishRemoteError publisher options err = do
  -- TODO: note why remote error cannot take encoding options
  let response = Proto.WrappedResponse $ Just $ Proto.WrappedResponseOrErrorError err
  client <- asks cfgClient
  topic <- askResponseTopic
  packetSizeLimit <- asks cfgMsgSize
  rateLimit <- asks cfgRateLimit

  Session.logError "publishing remote error as packets" (show response)

  Response.makeErrorResponseSender publisher client topic packetSizeLimit rateLimit options err

---------------------------------------------------------------------------------

-- TODO: This doesn't looks like it's used for anything?
-- makePacketReader ::
--   TQueue ByteString ->
--   Session (Either RemoteError ByteString)
-- makePacketReader channel = do
--   result <- runExceptT (Packet.makePacketReader channel)
--   case result of
--     Left err -> do
--       Session.logError "wire parse error encountered parsing Packet" (show err)
--       pure (Left $ parseErrorToRCE err)
--     Right bs -> do
--       Session.logDebug "read packets to ByteString" (show bs)
--       pure (Right bs)

handleStreamSend :: Publisher -> WireEncodeOptions -> StreamSend a -> a -> Session ()
handleStreamSend publisher options send x = do
  result <- liftIO (send x)
  case result of
    Right () -> pure ()
    Left err -> do
      Session.logError "gRPC IO error encountered handling StreamSend" (show err)
      publishGRPCIOError publisher options err

handleWritesDone :: Publisher -> WireEncodeOptions -> WritesDone -> Session ()
handleWritesDone publisher options done =
  liftIO done >>= \case
    Right () -> pure ()
    Left err -> do
      Session.logError "gRPC IO error encountered handling WritesDone" (show err)
      publishGRPCIOError publisher options err

---------------------------------------------------------------------------------

makeServerStreamSender ::
  Publisher ->
  OrderedTQueue ByteString ->
  WireEncodeOptions ->
  WireDecodeOptions ->
  StreamSend ByteString ->
  WritesDone ->
  Session ()
makeServerStreamSender publisher queue encodeOptions decodeOptions sender done = do
  reader <- makeClientStreamReader @_ queue decodeOptions
  fix \loop -> do
    runExceptT reader >>= \case
      Left err -> do
        handleWritesDone publisher encodeOptions done
        publishRemoteError publisher encodeOptions err
      Right Nothing ->
        handleWritesDone publisher encodeOptions done
      Right (Just x) -> do
        handleStreamSend publisher encodeOptions sender x
        loop

makeServerStreamReader ::
  Publisher ->
  WireEncodeOptions ->
  StreamRecv ByteString ->
  Session ()
makeServerStreamReader publisher options recv = do
  (send, done) <- makeStreamSender
  fix \loop ->
    liftIO recv >>= \case
      Left err -> do
        Session.logError "server stream reader: encountered error reading chunk" (show err)
        done
        publishGRPCIOError publisher options err
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
        liftIO (publisher client topic (fromStrict chunk))

---------------------------------------------------------------------------------

makeClientStreamReader ::
  (MonadError RemoteError m, MonadIO m) =>
  OrderedTQueue ByteString ->
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
  Publisher ->
  OrderedTQueue ByteString ->
  ProtoOptions ->
  StreamSend ByteString ->
  Session ()
makeClientStreamSender publisher queue options sender = do
  let encodeOptions = Serial.makeRemoteEncodeOptions options
  let decodeOptions = Serial.makeRemoteDecodeOptions options
  reader <- makeClientStreamReader queue decodeOptions
  fix \loop ->
    runExceptT reader >>= \case
      Left err -> publishRemoteError publisher encodeOptions err
      Right Nothing -> Session.logDebug "client stream sender" "done"
      Right (Just x) -> do
        Session.logDebug "client stream sender" "sending chunk"
        handleStreamSend publisher encodeOptions sender x
        loop
