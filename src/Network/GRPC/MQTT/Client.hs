-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskellQuotes #-}

-- | The client API for making gRPC requests over MQTT.
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Client
  ( MQTTGRPCClient (..),
    mqttRequest,
    withMQTTGRPCClient,
    connectMQTTGRPC,
    disconnectMQTTGRPC,

    -- * Topics
    -- $client-topics
    ClientTopicError
      ( BadSessionIdTopicError,
        BadRPCMethodTopicError
      ),
    makeSessionIdTopic,
    makeMethodRequestTopic,
  )
where

---------------------------------------------------------------------------------

import Control.Exception
  ( bracket,
    handle,
    onException,
    throwIO,
  )

import Control.Concurrent.Async qualified as Async

import Control.Concurrent.STM.TChan (TChan, newTChanIO, writeTChan)

import Control.Monad.Except (liftEither, withExceptT)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)

import Crypto.Nonce qualified as Nonce

import Data.ByteString qualified as ByteString

import Data.Text qualified as Text

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
    MQTTException,
    MessageCallback (SimpleCallback),
    normalDisconnect,
  )
import Network.MQTT.Topic (Topic (unTopic), mkTopic, toFilter)

import Proto3.Suite (Enumerated (Enumerated), HasDefault, Message)
import Proto3.Suite qualified as Proto3

import Relude

import System.Timeout qualified as System (timeout)

import Text.Show (ShowS, shows)
import Text.Show qualified as Show

import Turtle (sleep)

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Packet (packetReader)
import Network.GRPC.MQTT.Message.Request (Request (Request), wireWrapRequest)
import Network.GRPC.MQTT.Sequenced
  ( PublishToStream (..),
    mkPacketizedPublish,
    mkStreamPublish,
    mkStreamRead,
  )
import Network.GRPC.MQTT.Topic qualified as Topic
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
-- @since 0.1.0.0
data MQTTGRPCClient = MQTTGRPCClient
  { -- | The MQTT client
    mqttClient :: MQTTClient
  , -- | Channel for passing MQTT messages back to calling thread
    responseChan :: TChan LByteString
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
-- @since 0.1.0.0
withMQTTGRPCClient :: Logger -> MQTTGRPCConfig -> (MQTTGRPCClient -> IO a) -> IO a
withMQTTGRPCClient logger cfg =
  bracket
    (connectMQTTGRPC logger cfg)
    disconnectMQTTGRPC

-- | Send a gRPC request over MQTT using the provided client This function makes
-- synchronous requests.
--
-- @since 0.1.0.0
mqttRequest ::
  forall request response streamtype.
  (Message request, Message response, HasDefault request) =>
  MQTTGRPCClient ->
  Topic ->
  MethodName ->
  Batched ->
  MQTTRequest streamtype request response ->
  IO (MQTTResult streamtype response)
mqttRequest MQTTGRPCClient{..} baseTopic nmMethod useBatchedStream request = do
  logDebug mqttLogger $ "Making gRPC request for method: " <> show nmMethod

  handle handleMQTTException $ do
    sessionId <- makeSessionIdTopic rng
    let responseTopic = Topic.makeResponseTopic baseTopic sessionId
    let controlTopic = Topic.makeControlTopic baseTopic sessionId

    requestTopic <- makeMethodRequestTopic baseTopic sessionId nmMethod

    let publishToRequestTopic :: Message r => r -> IO ()
        publishToRequestTopic = mkPacketizedPublish mqttClient msgSizeLimit requestTopic . Proto3.toLazyByteString

    let publishRequest :: request -> TimeoutSeconds -> HL.MetadataMap -> IO ()
        publishRequest rqt timeout metadata = do
          let payload = toStrict (Proto3.toLazyByteString rqt)
          let encoded = wireWrapRequest (Request payload timeout metadata)
          logDebug mqttLogger $ "Publishing to topic: " <> unTopic requestTopic
          logDebug mqttLogger $ "Publishing message: " <> show encoded
          mkPacketizedPublish mqttClient msgSizeLimit requestTopic encoded

    let publishToControlTopic :: Message r => r -> IO ()
        publishToControlTopic = mkPacketizedPublish mqttClient msgSizeLimit controlTopic . Proto3.toLazyByteString

    let publishControlMsg :: AuxControl -> IO ()
        publishControlMsg ctrl = do
          let ctrlMessage = AuxControlMessage (Enumerated (Right ctrl))
          logDebug mqttLogger $ "Publishing control message " <> show ctrl <> " to topic: " <> unTopic controlTopic
          publishToControlTopic ctrlMessage

    PublishToStream{publishToStream, publishToStreamCompleted} <-
      mkStreamPublish msgSizeLimit useBatchedStream publishToRequestTopic
    let publishToRequestStream :: request -> IO (Either GRPCIOError ())
        publishToRequestStream req = do
          logDebug mqttLogger $ "Publishing stream chunk to topic: " <> unTopic requestTopic
          publishToStream req
          -- TODO: Fix this. Send errors won't be propagated to client's send handler
          return $ Right ()

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
      let errMsg = toText (displayException e)
      logErr mqttLogger errMsg
      return $ MQTTError errMsg

-- | Helper function to run an 'ExceptT RemoteError' action and convert any failure
-- to an 'MQTTResult'
--
-- @since 0.1.0.0
exceptToResult ::
  Functor f =>
  ExceptT RemoteError f (MQTTResult s rsp) ->
  f (MQTTResult s rsp)
exceptToResult = fmap (either fromRemoteError id) . runExceptT

-- | Manages the control signals (Heartbeat and Terminate) asynchronously while
-- the provided action performs a request
--
-- @since 0.1.0.0
withControlSignals :: (AuxControl -> IO ()) -> IO a -> IO a
withControlSignals publishControlMsg = withMQTTHeartbeat . sendTerminateOnException
  where
    withMQTTHeartbeat :: IO a -> IO a
    withMQTTHeartbeat action =
      Async.withAsync
        (forever (publishControlMsg AuxControlAlive >> sleep heartbeatPeriodSeconds))
        (const action)

    sendTerminateOnException :: IO a -> IO a
    sendTerminateOnException action =
      action `onException` publishControlMsg AuxControlTerminate

-- | Connects to the MQTT broker and creates a 'MQTTGRPCClient'
-- NB: Overwrites the '_msgCB' field in the 'MQTTConfig'
--
-- @since 0.1.0.0
connectMQTTGRPC :: MonadIO io => Logger -> MQTTGRPCConfig -> io MQTTGRPCClient
connectMQTTGRPC logger cfg = do
  chan <- liftIO newTChanIO

  let clientCallback :: MessageCallback
      clientCallback =
        SimpleCallback \_ topic msg _ -> do
          logDebug logger $ "clientMQTTHandler received message on topic: " <> unTopic topic
          logDebug logger $ " Raw: " <> decodeUtf8 (toStrict msg)
          atomically $ writeTChan chan msg

  conn <- connectMQTT cfg{_msgCB = clientCallback}
  uuid <- Nonce.new
  pure (MQTTGRPCClient conn chan uuid logger (fromIntegral (mqttMsgSizeLimit cfg)))

disconnectMQTTGRPC :: MonadIO io => MQTTGRPCClient -> io ()
disconnectMQTTGRPC client = liftIO (normalDisconnect (mqttClient client))

-- | Wraps a 'MQTTResult' computation in a 'Just' if it's result is avaliable
-- before the timeout period, given in unit seconds. In the case that the
-- timeout period expires before the computation finishes, a timeout error
-- is returned:
--
-- prop> GRPCResult (ClientErrorResponse (ClientIOError GRPCIOTimeout))
--
-- @since 0.1.0.0
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
-- @since 0.1.0.0
timeout'secs :: MonadUnliftIO m => TimeoutSeconds -> m a -> m (Maybe a)
timeout'secs period'secs action =
  -- @System.timeout@ expects the timeout period given to be in unit
  -- microseconds, multiplying by 1*10^6 converts the given @period'secs@ to
  -- microseconds (although using @1e6 * secs@ directly needs 'truncate').
  let period'usecs :: Int
      period'usecs = 1_000_000 * period'secs
   in withRunInIO \runIO ->
        System.timeout period'usecs (runIO action)

--------------------------------------------------------------------------------

-- $client-topics
--
-- MQTT topics used by the client in order to make requests to a remote client.

-- | 'ClientTopicError' captures all exceptions that can be raised when
-- constructing MQTT topics required by a client.
--
-- @since 0.1.0.0
data ClientTopicError
  = -- | Exception that is raised when the client generates a nonce that does
    -- not form a valid MQTT topic (this should be impossible).
    BadSessionIdTopicError Text
  | -- | Exception that is raised when preparing a request for RPC method with a
    -- name that does not form a valid MQTT topic.
    BadRPCMethodTopicError Text
  deriving stock (Eq, Ord, Typeable)

-- | @since 0.1.0.0
instance Exception ClientTopicError

-- | @since 0.1.0.0
instance Show ClientTopicError where
  show e = case e of
    BadSessionIdTopicError x ->
      formatS ("session ID " ++ show x) ++ " (impossible)"
    BadRPCMethodTopicError x ->
      formatS ("method name " ++ show x)
    where
      formatS :: ShowS
      formatS x = shows ''ClientTopicError ": " ++ x ++ " forms invalid topic"
  {-# INLINE show #-}

-- | Generates a new randomized 128-bit nonce word to use as a fresh session ID
-- topic.
--
-- /Note:/ Although it should __never__ happen, function can potentially throw
-- a 'BadSessionIdTopicError'.
--
-- >>> import qualified Crypto.Nonce -- from the package "nonce"
-- >>> makeSessionIdTopic =<< Crypto.Nonce.new
-- Topic {unTopic = "fA6L7xKY6_-qa7k3g3J7DZ-e"}
--
-- @since 0.1.0.0
makeSessionIdTopic :: Nonce.Generator -> IO Topic
makeSessionIdTopic gen = do
  uuid <- Nonce.nonce128urlT gen
  maybe (onError uuid) pure (mkTopic uuid)
  where
    -- The 'ByteString' produced by 'nonce128urlT' is known to alway form a
    -- valid MQTT topic. If this is thrown, it is very likely the implementation
    -- of @mkTopic@ has changed, this is impossible for version 0.8.1.0 of
    -- net-mqtt.
    onError :: Text -> IO a
    onError uuid = throwIO (BadSessionIdTopicError uuid)

-- | Constructs a session request topic for a given base topic, session ID, and
-- the 'MethodName' of the RPC requested.
--
-- /Note:/ This function will throw a 'BadRPCMethodTopicError' 'IO' exception
-- if the 'MethodName' provided would not form a valid MQTT topic.
--
-- >>> makeMethodRequestTopic "base.topic" "BgHY9DxnsLj7-IEq4IxTgqMg" "/proto.package.ServiceName/MyRPC"
-- Topic {unTopic = "base.topic/grpc/request/BgHY9DxnsLj7-IEq4IxTgqMg/proto-package-ServiceName/MyRPC"}
--
-- >>> -- The method "/bad/#/topic" forms an invalid topic (contains a '#')
-- >>> makeMethodRequestTopic "..." "..." "/bad/#/topic"
-- *** Exception: Network.GRPC.MQTT.Client.ClientTopicError: gRPC method name"/bad/#/topic" forms invalid topic
--
-- @since 0.1.0.0
makeMethodRequestTopic :: Topic -> Topic -> MethodName -> IO Topic
makeMethodRequestTopic baseTopic sid (MethodName nm) =
  -- Some MQTT implementations (for e.g. RabbitMQ) can't handle dots
  -- in topic names. We replace them with hyphens. This is unambiguous
  -- because hyphens cannot occur in method names.
  let escapeDots :: Text -> Text
      escapeDots = Text.map \case
        '.' -> '-'
        c -> c

      -- The leading '/' character is removed via @drop 1@ since the 'Semigroup'
      -- instance for 'Topic' automatically inserts '/' slashes when joining
      -- topics.
      methodTopic :: Maybe Topic
      methodTopic = mkTopic . escapeDots . decodeUtf8 . ByteString.drop 1 $ nm
   in case methodTopic of
        Nothing -> throwIO (BadRPCMethodTopicError (decodeUtf8 nm))
        Just ts -> pure (baseTopic <> "grpc" <> "request" <> sid <> ts)
