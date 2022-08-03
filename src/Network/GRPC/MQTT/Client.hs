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
    ClientTopicError (BadSessionIdTopicError, BadRPCMethodTopicError),
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

import Control.Monad.Except (throwError, withExceptT)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)

import Crypto.Nonce qualified as Nonce

import Data.ByteString qualified as ByteString
import Data.Map qualified as Map
import Data.Text qualified as Text

import Network.GRPC.HighLevel
  ( GRPCIOError (GRPCIOTimeout),
    MetadataMap,
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
import Network.GRPC.MQTT.Core
  ( MQTTGRPCConfig (_msgCB),
    connectMQTT,
    heartbeatPeriodSeconds,
    mqttMsgSizeLimit,
    subscribeOrThrow,
  )
import Network.GRPC.MQTT.Logging (Logger, logDebug, logErr)
import Network.MQTT.Client
  ( MQTTClient,
    MQTTException,
    MessageCallback (SimpleCallback),
    QoS (QoS1),
    normalDisconnect,
    publishq,
  )
import Network.MQTT.Topic (Topic (unTopic), mkTopic, toFilter)

import Proto3.Suite (Enumerated (Enumerated), HasDefault, Message)
import Proto3.Suite qualified as Proto3

import Relude hiding (reader)

import System.Timeout qualified as System (timeout)

import Text.Show (ShowS, shows)
import Text.Show qualified as Show

import Turtle (sleep)

---------------------------------------------------------------------------------

import Network.GRPC.HighLevel.Extra (wireDecodeMetadataMap)

import Network.GRPC.MQTT.Message qualified as Message
import Network.GRPC.MQTT.Message.AuxControl
  ( AuxControl (AuxControlAlive, AuxControlTerminate),
    AuxControlMessage (AuxControlMessage),
  )
import Network.GRPC.MQTT.Message.Packet qualified as Packet
import Network.GRPC.MQTT.Message.Request qualified as Request
import Network.GRPC.MQTT.Message.Response qualified as Response
import Network.GRPC.MQTT.Message.Stream qualified as Stream

import Network.GRPC.MQTT.Option (ProtoOptions)

import Network.GRPC.MQTT.Serial (WireDecodeOptions)
import Network.GRPC.MQTT.Serial qualified as Serial

import Network.GRPC.MQTT.Topic qualified as Topic
import Network.GRPC.MQTT.Types
  ( MQTTRequest
      ( MQTTBiDiRequest,
        MQTTNormalRequest,
        MQTTReaderRequest,
        MQTTWriterRequest
      ),
    MQTTResult (GRPCResult, MQTTError),
    requestTimeout,
  )

import Network.GRPC.MQTT.Wrapping
  ( fromRemoteError,
    parseErrorToRCE,
    toGRPCIOError,
  )

import Proto.Mqtt (RemoteError)

---------------------------------------------------------------------------------

-- | Client for making gRPC calls over MQTT
--
-- @since 0.1.0.0
data MQTTGRPCClient = MQTTGRPCClient
  { -- | The MQTT client
    mqttClient :: MQTTClient
  , -- | Channel for passing MQTT messages back to calling thread
    responseChans :: IORef (Map Topic (TChan LByteString))
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
  ProtoOptions ->
  MQTTRequest streamtype request response ->
  IO (MQTTResult streamtype response)
mqttRequest MQTTGRPCClient{..} baseTopic nmMethod options request = do
  logDebug mqttLogger $ "Making gRPC request for method: " <> show nmMethod

  handle handleMQTTException $ do
    sessionId <- makeSessionIdTopic rng
    responsechan <- newTChanIO 


    -- Topics
    let responseTopic = Topic.makeResponseTopic baseTopic sessionId
    let controlTopic = Topic.makeControlTopic baseTopic sessionId

    atomicModifyIORef' responseChans \cxs -> 
      (Map.insert responseTopic responsechan cxs, ())

    -- Message options
    let encodeOptions = Serial.makeClientEncodeOptions options
    let decodeOptions = Serial.makeRemoteDecodeOptions options
    let timeout = requestTimeout request
    let limit = fromIntegral msgSizeLimit

    requestTopic <- makeMethodRequestTopic baseTopic sessionId nmMethod

    (publishToStream, publishToStreamCompleted) <-
      Stream.makeStreamBatchSender limit encodeOptions \message -> do
        logDebug mqttLogger $ "client debug: publishing stream chunk to topic: " <> unTopic requestTopic
        publishq mqttClient requestTopic (fromStrict message) False QoS1 []

    let publishToRequestStream :: request -> IO (Either GRPCIOError ())
        publishToRequestStream x =
          -- TODO: Fix this. Send errors won't be propagated to client's send handler
          let message :: ByteString
              message = Message.toWireEncoded encodeOptions x
           in publishToStream message $> Right ()

    -- Subscribe to response topic
    subscribeOrThrow mqttClient [toFilter responseTopic]

    -- Process request
    timeoutGRPC timeout do
      Request.makeRequestSender
        limit
        (\x -> publishq mqttClient requestTopic (fromStrict x) False QoS1 [])
        (Message.toWireEncoded encodeOptions <$> Request.fromMQTTRequest options request)

      withControlSignals (publishControl controlTopic) . exceptToResult $ do
        case request of
          -- Unary Requests
          MQTTNormalRequest _ _ _ ->
            Response.makeNormalResponseReader responsechan decodeOptions
          -- Client Streaming Requests
          MQTTWriterRequest _ _ streamHandler -> do
            liftIO $ do
              -- do client streaming
              streamHandler publishToRequestStream
              -- Send end of stream indicator
              publishToStreamCompleted

            Response.makeClientResponseReader responsechan decodeOptions

          -- Server Streaming Requests
          MQTTReaderRequest _ _ _ streamHandler -> do
            -- Wait for initial metadata
            metadata <- makeMetadataMapReader responsechan decodeOptions

            reader <- Stream.makeStreamReader responsechan decodeOptions

            let mqttSRecv :: StreamRecv response
                mqttSRecv = runExceptT $ withExceptT toGRPCIOError do
                  reader >>= \case
                    Nothing -> pure Nothing
                    Just bs -> withExceptT Message.toRemoteError do
                      Just <$> Message.fromWireEncoded @_ @response decodeOptions bs

            -- Run user-provided stream handler
            liftIO (streamHandler metadata mqttSRecv)

            -- Return final result
            Response.makeServerResponseReader responsechan decodeOptions

          -- BiDirectional Server Streaming Requests
          MQTTBiDiRequest _ _ streamHandler -> do
            -- Wait for initial metadata
            metadata <- makeMetadataMapReader responsechan decodeOptions

            reader <- Stream.makeStreamReader responsechan decodeOptions

            let mqttSRecv :: StreamRecv response
                mqttSRecv = runExceptT $ withExceptT toGRPCIOError do
                  chunk <- reader
                  case chunk of
                    Nothing -> pure Nothing
                    Just bs -> withExceptT Message.toRemoteError do
                      Just <$> Message.fromWireEncoded decodeOptions bs

            let mqttSSend :: StreamSend request
                mqttSSend = publishToRequestStream

            let mqttWritesDone :: WritesDone
                mqttWritesDone = do
                  publishToStreamCompleted
                  return $ Right ()

            -- Run user-provided stream handler
            liftIO $ streamHandler metadata mqttSRecv mqttSSend mqttWritesDone

            -- Return final result
            Response.makeBiDiResponseReader responsechan decodeOptions
  where
    makeMetadataMapReader ::
      TChan LByteString ->
      WireDecodeOptions ->
      ExceptT RemoteError IO MetadataMap
    makeMetadataMapReader channel decodeOptions = do
      bytes <- withExceptT Message.toRemoteError do
        Packet.makePacketReader channel decodeOptions
      case wireDecodeMetadataMap bytes of
        Left err -> throwError (parseErrorToRCE err)
        Right rx -> pure rx

    publishControl :: Topic -> AuxControl -> IO ()
    publishControl ctrlTopic ctrl = do
      logDebug mqttLogger $ "Publishing control message " <> show ctrl <> " to topic: " <> unTopic ctrlTopic
      let encoded :: LByteString
          encoded = Proto3.toLazyByteString (AuxControlMessage (Enumerated (Right ctrl)))
       in publishq mqttClient ctrlTopic encoded False QoS1 []

    handleMQTTException :: MQTTException -> IO (MQTTResult streamtype response)
    handleMQTTException e = do
      let errMsg = toText (displayException e)
      logErr mqttLogger errMsg
      return $ MQTTError errMsg

-- | Helper function to run an 'ExceptT RemoteError' action and convert any failure
-- to an 'MQTTResult'
--
-- @since 0.1.0.0
exceptToResult :: Functor f => ExceptT RemoteError f (MQTTResult s rsp) -> f (MQTTResult s rsp)
exceptToResult = fmap (either fromRemoteError id) . runExceptT

-- | Manages the control signals (Heartbeat and Terminate) asynchronously while
-- the provided action performs a request
--
-- @since 0.1.0.0
withControlSignals :: (AuxControl -> IO ()) -> IO a -> IO a
withControlSignals publishControlMsg =
  withMQTTHeartbeat . sendTerminateOnException
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
  chans <- newIORef Map.empty
  uuid <- Nonce.new

  let clientCallback :: MessageCallback
      clientCallback =
        SimpleCallback \_ topic msg _ -> do
          cxs <- readIORef chans 
          case Map.lookup topic cxs of 
            Nothing -> do
              logDebug logger $ "no such response topic: " <> unTopic topic
            Just chan -> do 
              logDebug logger $ "clientMQTTHandler received message on topic: " <> unTopic topic
              logDebug logger $ " Raw: " <> decodeUtf8 (toStrict msg)
              atomically $ writeTChan chan msg

  conn <- connectMQTT cfg{_msgCB = clientCallback}

  pure (MQTTGRPCClient conn chans uuid logger (fromIntegral (mqttMsgSizeLimit cfg)))

disconnectMQTTGRPC :: MonadIO io => MQTTGRPCClient -> io ()
disconnectMQTTGRPC client = liftIO (normalDisconnect (mqttClient client))

-- | Wraps a 'MQTTResult' computation in a 'Just' if it's result is avaliable
-- before the timeout period, given in unit seconds. In the case that the
-- timeout period expires before the computation finishes, a timeout error
-- is returned:
--
-- @'GRPCResult' ('ClientErrorResponse' ('ClientIOError' 'GRPCIOTimeout'))@
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

-- Topics ----------------------------------------------------------------------

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
    BadSessionIdTopicError x -> formatS ("session ID " ++ show x)
    BadRPCMethodTopicError x -> formatS ("method name " ++ show x)
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
