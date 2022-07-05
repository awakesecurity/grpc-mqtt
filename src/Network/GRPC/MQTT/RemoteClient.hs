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

import Control.Concurrent.STM.TChan (TChan, writeTChan)

import Control.Exception (bracket)
import Control.Exception.Safe (handleAny)

import Control.Monad.Except (throwError)
import Control.Monad.IO.Unlift (withRunInIO)

import Data.List (stripPrefix)
import Data.Text qualified as Text

import Network.GRPC.HighLevel (GRPCIOError, StreamRecv, StreamSend)
import Network.GRPC.HighLevel.Client
  ( ClientError (ClientIOError),
    ClientResult,
    WritesDone,
  )

import Network.MQTT.Client
  ( MQTTClient,
    MessageCallback (SimpleCallback),
    normalDisconnect,
    waitForClient,
  )
import Network.MQTT.Topic (Filter, Topic)
import Network.MQTT.Topic qualified as Topic

import Proto3.Suite (Enumerated (Enumerated), Message)
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
    subscribeOrThrow,
  )

import Network.GRPC.MQTT.Logging (Logger)
import Network.GRPC.MQTT.Logging qualified as Logger

import Network.GRPC.MQTT.Message.Packet qualified as Packet
import Network.GRPC.MQTT.Message.Request (Request (Request), wireUnwrapRequest)
import Network.GRPC.MQTT.Message.Request qualified as Request

import Network.GRPC.MQTT.Option.Batched (Batched)

import Network.GRPC.MQTT.RemoteClient.Session
import Network.GRPC.MQTT.RemoteClient.Session qualified as Session

import Network.GRPC.MQTT.Sequenced
  ( PublishToStream (..),
    mkPacketizedPublish,
    mkStreamPublish,
    mkStreamRead,
  )
import Network.GRPC.MQTT.Topic (makeControlFilter, makeRequestFilter)
import Network.GRPC.MQTT.Types (ClientHandler (..), MethodMap)

import Network.GRPC.MQTT.Wrapping (parseErrorToRCE, wrapResponse)
import Network.GRPC.MQTT.Wrapping qualified as Wrapping

import Proto.Mqtt
  ( AuxControl (AuxControlAlive, AuxControlTerminate),
    AuxControlMessage (AuxControlMessage),
    RemoteError,
    WrappedResponse (WrappedResponse),
    WrappedResponseOrError
      ( WrappedResponseOrErrorError
      ),
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
        Right ctrl -> do
          -- TODO: cancel hdlThread and abort
          Logger.logWarn logger $ "Received unknown control message: " <> show ctrl
        Left err -> do
          -- TODO: cancel hdlThread and abort
          Logger.logErr logger $ "Failed to parse control message: " <> show err

-- | TODO
--
-- @since 0.1.0.0
handleRequest :: SessionHandle -> Session ()
handleRequest handle = do
  let channel = hdlRqtChan handle
  bytes <- makePacketReader channel
  case remoteParseRequest =<< bytes of
    Left err -> do
      Session.logError "wire parse error encountered parsing Request" (show err)
      publishRemoteError err
    Right rqt@Request{..} -> do
      Session.logDebug "handling client request" (show rqt)
      dispatchClientHandler \clientHandler ->
        publishResponse =<< case clientHandler of
          ClientUnaryHandler k -> do
            result <- liftIO (k message timeout metadata)
            pure (makeClientResponse result)
          ClientClientStreamHandler k -> 
            withRunInIO \runIO -> do
              let sender = makeClientStreamSender channel
              result <- k timeout metadata (runIO . sender)
              pure (makeClientResponse result)
          ClientServerStreamHandler batch k -> do
            withRunInIO \runIO -> do
              result <- k message timeout metadata \_ ms recv -> runIO do
                publishPackets (wireEncodeMetadataMap ms)
                makeServerStreamReader batch recv
              pure (makeClientResponse result)
          ClientBiDiStreamHandler batch k ->
            withRunInIO \runIO -> do
              result <- k timeout metadata \_ ms recv send done -> runIO do
                publishPackets (wireEncodeMetadataMap ms)
                let reader = makeServerStreamReader batch recv
                    sender = makeServerStreamSender channel send done
                 in concurrently_ sender reader
              pure (makeClientResponse result)
  where
    makeClientResponse :: Message a => ClientResult s a -> WrappedResponse
    makeClientResponse x = wrapResponse (toStrict . Proto3.toLazyByteString <$> x)

    remoteParseRequest :: ByteString -> Either RemoteError (Request ByteString)
    remoteParseRequest bytes =
      case wireUnwrapRequest bytes of
        Left err -> throwError (parseErrorToRCE err)
        Right rqt -> pure rqt

    publishResponse :: WrappedResponse -> Session ()
    publishResponse response = do
      Session.logDebug "publishing wrapped client response" (show response)
      publishPackets (Proto3.toLazyByteString response)

-- | TODO
--
-- @since 0.1.0.0
dispatchClientHandler :: (ClientHandler -> Session ()) -> Session ()
dispatchClientHandler k = maybe onError k =<< askMethod
  where
    -- FIXME: The error message's details are lost in transit to the client.
    onError :: Session ()
    onError = do
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
       in publishRemoteError (Proto.RemoteError etype ecall extra)

---------------------------------------------------------------------------------

publishPackets :: LByteString -> Session ()
publishPackets message = do
  client <- asks cfgClient
  limit <- asks (fromIntegral . cfgMsgSize)
  topic <- askResponseTopic

  Session.logDebug "publishing message as packets" (show message)
  Session.logDebug "...to the response topic" (Topic.unTopic topic)

  mkPacketizedPublish client limit topic message

publishGRPCIOError :: GRPCIOError -> Session ()
publishGRPCIOError err = do
  let message = Wrapping.toRemoteError (ClientIOError err)
  let response = WrappedResponse (Just (WrappedResponseOrErrorError message))
  publishPackets (Proto3.toLazyByteString response)

-- | Encodes the given 'RemoteError', and publishes it to the topic provided.
--
-- @since 0.1.0.0
publishRemoteError :: RemoteError -> Session ()
publishRemoteError err = do
  let message = Proto.WrappedResponse $ Just $ Proto.WrappedResponseOrErrorError $ err
  client <- asks cfgClient
  limit <- asks (fromIntegral . cfgMsgSize)
  topic <- askResponseTopic

  Session.logError "publishing remote error as packets" (show message)
  Session.logError "...to the response topic" (Topic.unTopic topic)

  mkPacketizedPublish client limit topic (Proto3.toLazyByteString message)

---------------------------------------------------------------------------------

makePacketReader :: TChan LByteString -> Session (Either RemoteError ByteString)
makePacketReader channel = do
  result <- liftIO (Packet.packetReader channel)
  case result of
    Left err -> do
      Session.logError "wire parse error encountered parsing Packet" (show err)
      pure (Left $ parseErrorToRCE err)
    Right bs -> do
      Session.logDebug "read packets to ByteString" (show bs)
      pure (Right $ toStrict bs)

handleStreamSend :: StreamSend a -> a -> Session ()
handleStreamSend send x = do
  result <- liftIO (send x)
  case result of
    Right () -> pure ()
    Left err -> do
      Session.logError "gRPC IO error encountered handling StreamSend" (show err)
      publishGRPCIOError err

handleWritesDone :: WritesDone -> Session ()
handleWritesDone done =
  liftIO done >>= \case
    Right () -> pure ()
    Left err -> do
      Session.logError "gRPC IO error encountered handling WritesDone" (show err)
      publishGRPCIOError err

---------------------------------------------------------------------------------

makeServerStreamSender ::
  Message a =>
  TChan LByteString ->
  StreamSend a ->
  WritesDone ->
  Session ()
makeServerStreamSender channel sender done = do
  reader <- makeClientStreamReader channel
  fix \loop -> 
    liftIO reader >>= \case
      Left err -> do
        handleWritesDone done
        publishRemoteError err
      Right Nothing -> 
        handleWritesDone done
      Right (Just x) -> do
        handleStreamSend sender x
        loop

makeServerStreamReader :: Message a => Batched -> StreamRecv a -> Session ()
makeServerStreamReader batch recv = do
  limit <- asks (fromIntegral . cfgMsgSize)
  stream <- withRunInIO \runIO ->
    mkStreamPublish limit batch \chunk -> do
      runIO (publishPackets (Proto3.toLazyByteString chunk))

  fix \loop ->
    liftIO recv >>= \case
      Left err -> do
        liftIO (publishToStreamCompleted stream)
        publishGRPCIOError err
      Right Nothing ->
        liftIO (publishToStreamCompleted stream)
      Right (Just rsp) -> do
        liftIO (publishToStream stream rsp)
        loop

---------------------------------------------------------------------------------

makeClientStreamReader ::
  Message a =>
  TChan LByteString ->
  Session (IO (Either RemoteError (Maybe a)))
makeClientStreamReader channel =
  withRunInIO \runIO -> do
    reader <- mkStreamRead $ ExceptT do
      result <- runIO (makePacketReader channel)
      pure (fmap fromStrict result)
    pure (runExceptT reader)

makeClientStreamSender :: Message a => TChan LByteString -> StreamSend a -> Session ()
makeClientStreamSender channel sender = do
  reader <- makeClientStreamReader channel
  fix \loop -> 
    liftIO reader >>= \case
      Left err -> do
        Session.logError "parse error encountered reading stream chunk" (show err)
        publishRemoteError err
      Right Nothing -> 
        Session.logDebug "server stream sender" "done"
      Right (Just x) -> do
        Session.logDebug "server stream sender" "read chunk"
        handleStreamSend sender x
        loop 