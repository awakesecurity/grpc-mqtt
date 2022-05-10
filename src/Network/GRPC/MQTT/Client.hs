-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.Client
  ( MQTTGRPCClient (..),
    mqttRequest,
    withMQTTGRPCClient,
    connectMQTTGRPC,
    disconnectMQTTGRPC,
  )
where

---------------------------------------------------------------------------------

import Control.Exception (bracket, displayException, handle, onException, throw)

import Control.Concurrent.Async qualified as Async

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, newTChanIO, writeTChan)

import Control.Monad (forever)
import Control.Monad.Except (ExceptT, liftEither, runExceptT, withExceptT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.IO.Unlift (MonadUnliftIO, toIO)

import Crypto.Nonce qualified as Nonce

import Data.Int (Int64)
import Data.Maybe (fromMaybe)

import Data.ByteString.Lazy qualified as Lazy (ByteString)
import Data.ByteString.Lazy qualified as Lazy.ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding

import Network.GRPC.HighLevel
  ( GRPCIOError (GRPCIOTimeout),
    MethodName (MethodName),
    StreamRecv,
    StreamSend,
  )
import Network.GRPC.HighLevel.Client
  ( ClientError (ClientIOError),
    ClientResult (ClientErrorResponse),
    TimeoutSeconds,
    WritesDone,
  )
import Network.GRPC.HighLevel.Generated qualified as HL
import Network.GRPC.MQTT.Core
  ( MQTTGRPCConfig (_msgCB),
    connectMQTT,
    heartbeatPeriodSeconds,
    mqttMsgSizeLimit,
    subscribeOrThrow,
  )
import Network.GRPC.MQTT.Logging (Logger, logDebug, logErr)
import Network.GRPC.MQTT.Types
  ( Batched,
    MQTTRequest (MQTTBiDiRequest, MQTTNormalRequest, MQTTReaderRequest, MQTTWriterRequest),
    MQTTResult (GRPCResult, MQTTError),
  )
import Network.MQTT.Client
  ( MQTTClient,
    MQTTException (MQTTException),
    MessageCallback (SimpleCallback),
    normalDisconnect,
  )
import Network.MQTT.Topic (Topic (unTopic), mkTopic, toFilter)

import Proto3.Suite (Enumerated (Enumerated), HasDefault, Message)
import Proto3.Suite qualified as Proto3

import System.Timeout qualified as System (timeout)

import Turtle (sleep)

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Request (Request (Request), wireWrapRequest)
import Network.GRPC.MQTT.Sequenced
  ( PublishToStream (..),
    mkPacketizedPublish,
    mkStreamPublish,
    mkStreamRead,
    packetReader,
  )
import Network.GRPC.MQTT.Wrapping
  ( fromRemoteError,
    parseErrorToRCE,
    parseMessageOrError,
    toGRPCIOError,
    toMetadataMap,
    unwrapBiDiStreamResponse,
    unwrapClientStreamResponse,
    unwrapServerStreamResponse,
    unwrapUnaryResponse,
  )

import Proto.Mqtt
  ( AuxControl (AuxControlAlive, AuxControlTerminate),
    AuxControlMessage (AuxControlMessage),
    RemoteError,
  )

---------------------------------------------------------------------------------

-- | Client for making gRPC calls over MQTT
--
-- @since 1.0.0
data MQTTGRPCClient = MQTTGRPCClient
  { -- | The MQTT client
    mqttClient :: MQTTClient
  , -- | Channel for passing MQTT messages back to calling thread
    responseChan :: TChan Lazy.ByteString
  , -- | Random number generator for generating session IDs
    rng :: Nonce.Generator
  , -- | Logging
    mqttLogger :: Logger
  , -- | Maximum size for an MQTT message in bytes
    msgSizeLimit :: Int64
  }

-- | Connects to the MQTT broker using the supplied 'MQTTConfig' and passes the
-- `MQTTGRPCClient' to the supplied function, closing the connection for you when
-- the function finishes.
--
-- @since 1.0.0
withMQTTGRPCClient :: Logger -> MQTTGRPCConfig -> (MQTTGRPCClient -> IO a) -> IO a
withMQTTGRPCClient logger cfg =
  bracket
    (connectMQTTGRPC logger cfg)
    disconnectMQTTGRPC

-- | Send a gRPC request over MQTT using the provided client This function makes
-- synchronous requests.
--
-- @since 1.0.0
mqttRequest ::
  forall request response streamtype.
  (Message request, Message response, HasDefault request) =>
  MQTTGRPCClient ->
  Topic ->
  MethodName ->
  Batched ->
  MQTTRequest streamtype request response ->
  IO (MQTTResult streamtype response)
mqttRequest MQTTGRPCClient{..} baseTopic (MethodName method) useBatchedStream request = do
  logDebug mqttLogger $ "Making gRPC request for method: " <> Text.Encoding.decodeUtf8 method

  handle handleMQTTException $ do
    sessionId <- generateSessionId rng
    let responseTopic = baseTopic <> "grpc" <> "session" <> sessionId
    let controlTopic = responseTopic <> "control"
    let baseRequestTopic = baseTopic <> "grpc" <> "request" <> sessionId

    requestTopic <- case mkTopic (Text.Encoding.decodeUtf8 method) of
      Nothing -> throw (MQTTException ("gRPC method forms invalid topic: " <> show method))
      Just topic -> pure (baseRequestTopic <> topic)

    -- `whenNothing` throw (MQTTException $ "gRPC method forms invalid topic: " <> decodeUtf8 method)

    publishReq' <- mkPacketizedPublish mqttClient msgSizeLimit requestTopic
    let publishToRequestTopic :: Message r => r -> IO ()
        publishToRequestTopic = publishReq' . Proto3.toLazyByteString

    let publishRequest :: request -> TimeoutSeconds -> HL.MetadataMap -> IO ()
        publishRequest rqt timeout metadata = do
          let payload = Lazy.ByteString.toStrict (Proto3.toLazyByteString rqt)
          let encoded = wireWrapRequest (Request payload timeout metadata)
          logDebug mqttLogger $ "Publishing to topic: " <> unTopic requestTopic
          logDebug mqttLogger $ "Publishing message: " <> Text.pack (show encoded)
          publishReq' encoded

    publishCtrl' <- mkPacketizedPublish mqttClient msgSizeLimit controlTopic
    let publishToControlTopic :: Message r => r -> IO ()
        publishToControlTopic = publishCtrl' . Proto3.toLazyByteString

    let publishControlMsg :: AuxControl -> IO ()
        publishControlMsg ctrl = do
          let ctrlMessage = AuxControlMessage (Enumerated (Right ctrl))
          logDebug mqttLogger $ "Publishing control message " <> Text.pack (show ctrl) <> " to topic: " <> unTopic controlTopic
          publishToControlTopic ctrlMessage

    PublishToStream{publishToStream, publishToStreamCompleted} <- mkStreamPublish msgSizeLimit useBatchedStream publishToRequestTopic
    let publishToRequestStream :: request -> IO (Either GRPCIOError ())
        publishToRequestStream req = do
          logDebug mqttLogger $ "Publishing stream chunk to topic: " <> unTopic requestTopic
          publishToStream req
          -- TODO: Fix this. Send errors won't be propagated to client's send handler
          return $ Right ()

    -- readResponseTopic <- mkPacketizedRead responseChan

    -- Subscribe to response topic
    subscribeOrThrow mqttClient [toFilter responseTopic]

    -- Process request
    case request of
      -- Unary Requests
      MQTTNormalRequest req timeLimit reqMetadata -> do
        timeoutGRPC timeLimit $ do
          publishRequest req timeLimit reqMetadata
          withControlSignals publishControlMsg . exceptToResult $ do
            rsp <- withExceptT parseErrorToRCE (packetReader responseChan)
            liftEither $ unwrapUnaryResponse rsp

      -- Client Streaming Requests
      MQTTWriterRequest timeLimit initMetadata streamHandler -> do
        timeoutGRPC timeLimit $ do
          publishRequest Proto3.def timeLimit initMetadata
          withControlSignals publishControlMsg . exceptToResult $ do
            liftIO $ do
              -- do client streaming
              streamHandler publishToRequestStream
              -- Send end of stream indicator
              publishToStreamCompleted

            rsp <- withExceptT parseErrorToRCE (packetReader responseChan)
            liftEither $ unwrapClientStreamResponse rsp

      -- Server Streaming Requests
      MQTTReaderRequest req timeLimit reqMetadata streamHandler ->
        timeoutGRPC timeLimit $ do
          publishRequest req timeLimit reqMetadata
          withControlSignals publishControlMsg . exceptToResult $ do
            -- Wait for initial metadata
            rawInitMetadata <- withExceptT parseErrorToRCE (packetReader responseChan)
            metadata <- liftEither $ parseMessageOrError rawInitMetadata

            readResponseStream <- mkStreamRead $ withExceptT parseErrorToRCE (packetReader responseChan)

            let mqttSRecv :: StreamRecv response
                mqttSRecv = runExceptT . withExceptT toGRPCIOError $ readResponseStream

            -- Run user-provided stream handler
            liftIO (streamHandler (toMetadataMap metadata) mqttSRecv)

            -- Return final result
            rsp <- withExceptT parseErrorToRCE (packetReader responseChan)
            liftEither $ unwrapServerStreamResponse rsp

      -- BiDirectional Server Streaming Requests
      MQTTBiDiRequest timeLimit reqMetadata streamHandler ->
        timeoutGRPC timeLimit $ do
          publishRequest Proto3.def timeLimit reqMetadata
          withControlSignals publishControlMsg . exceptToResult $ do
            -- Wait for initial metadata
            rawInitMetadata <- withExceptT parseErrorToRCE (packetReader responseChan)
            metadata <- liftEither $ parseMessageOrError rawInitMetadata

            readResponseStream <- mkStreamRead $ withExceptT parseErrorToRCE (packetReader responseChan)
            let mqttSRecv :: StreamRecv response
                mqttSRecv = runExceptT . withExceptT toGRPCIOError $ readResponseStream

            let mqttSSend :: StreamSend request
                mqttSSend = publishToRequestStream

            let mqttWritesDone :: WritesDone
                mqttWritesDone = do
                  publishToStreamCompleted
                  return $ Right ()

            -- Run user-provided stream handler
            liftIO $ streamHandler (toMetadataMap metadata) mqttSRecv mqttSSend mqttWritesDone

            -- Return final result
            rsp <- withExceptT parseErrorToRCE (packetReader responseChan)
            liftEither $ unwrapBiDiStreamResponse rsp
  where
    handleMQTTException :: MQTTException -> IO (MQTTResult streamtype response)
    handleMQTTException e = do
      let errMsg = Text.pack (displayException e)
      logErr mqttLogger errMsg
      return $ MQTTError errMsg

-- | Helper function to run an 'ExceptT RemoteError' action and convert any failure
-- to an 'MQTTResult'
--
-- @since 1.0.0
exceptToResult ::
  Functor f =>
  ExceptT RemoteError f (MQTTResult s rsp) ->
  f (MQTTResult s rsp)
exceptToResult = fmap (either fromRemoteError id) . runExceptT

-- | Manages the control signals (Heartbeat and Terminate) asynchronously while
-- the provided action performs a request
--
-- @since 1.0.0
withControlSignals :: (AuxControl -> IO ()) -> IO a -> IO a
withControlSignals publishControlMsg = withMQTTHeartbeat . sendTerminateOnException
  where
    withMQTTHeartbeat :: IO a -> IO a
    withMQTTHeartbeat action = do
      Async.withAsync
        (forever (publishControlMsg AuxControlAlive >> sleep heartbeatPeriodSeconds))
        (const action)

    sendTerminateOnException :: IO a -> IO a
    sendTerminateOnException action =
      action `onException` publishControlMsg AuxControlTerminate

-- | Connects to the MQTT broker and creates a 'MQTTGRPCClient'
-- NB: Overwrites the '_msgCB' field in the 'MQTTConfig'
--
-- @since 1.0.0
connectMQTTGRPC :: MonadIO io => Logger -> MQTTGRPCConfig -> io MQTTGRPCClient
connectMQTTGRPC logger cfg = do
  chan <- liftIO newTChanIO

  let clientCallback :: MessageCallback
      clientCallback =
        SimpleCallback \_ topic msg _ -> do
          logDebug logger $ "clientMQTTHandler received message on topic: " <> unTopic topic
          logDebug logger $ " Raw: " <> Text.Encoding.decodeUtf8 (Lazy.ByteString.toStrict msg)
          atomically $ writeTChan chan msg

  conn <- connectMQTT cfg{_msgCB = clientCallback}
  uuid <- Nonce.new
  pure (MQTTGRPCClient conn chan uuid logger (fromIntegral (mqttMsgSizeLimit cfg)))

-- | TODO
--
-- @since 1.0.0
disconnectMQTTGRPC :: MonadIO io => MQTTGRPCClient -> io ()
disconnectMQTTGRPC client = liftIO (normalDisconnect (mqttClient client))

-- | Wraps a 'MQTTResult' computation in a 'Just' if it's result is avaliable
-- before the timeout period, given in unit seconds. In the case that the
-- timeout period expires before the computation finishes, a timeout error
-- is returned:
--
-- prop> GRPCResult (ClientErrorResponse (ClientIOError GRPCIOTimeout))
--
-- @since 1.0.0
timeoutGRPC ::
  MonadUnliftIO m =>
  TimeoutSeconds ->
  m (MQTTResult s rsp) ->
  m (MQTTResult s rsp)
timeoutGRPC timelimit'secs action = do
  result <- timeout'secs timelimit'secs action
  pure (fromMaybe onExpired result)
  where
    onExpired :: MQTTResult s rsp
    onExpired = GRPCResult (ClientErrorResponse (ClientIOError GRPCIOTimeout))

-- | A variant of 'System.timeout' that accepts the timeout period in unit
-- seconds (as opposed to microseconds).
--
-- @since 1.0.0
timeout'secs :: MonadUnliftIO m => TimeoutSeconds -> m a -> m (Maybe a)
timeout'secs period'secs action =
  -- @System.timeout@ expects the timeout period given to be in unit
  -- microseconds, multiplying by 1*10^6 converts the given @period'secs@ to
  -- microseconds (although using @1e6 * secs@ directly needs 'truncate').
  let period'usecs :: Int
      period'usecs = 1_000_000 * period'secs
   in liftIO . System.timeout period'usecs =<< toIO action

-- | Generates a new randomized 128-bit nonce word to use as a fresh remote
-- client session ID 'Topic'.
--
-- @since 1.0.0
generateSessionId :: Nonce.Generator -> IO Topic
generateSessionId gen = do
  uuid <- Nonce.nonce128urlT gen
  maybe onError pure (mkTopic uuid)
  where
    onError :: IO a
    onError =
      -- If this is thrown, it is very likely the implementation of @mkTopic@
      -- has changed, this is impossible for version 0.8.1.0 of net-mqtt.
      let exc :: String
          exc = "grpc-mqtt: internal error: session ID to generate (impossible)"
       in throw (MQTTException exc)
