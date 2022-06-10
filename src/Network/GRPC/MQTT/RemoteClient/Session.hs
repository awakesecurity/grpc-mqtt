{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE StandaloneKindSignatures #-}

-- |
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.RemoteClient.Session
  ( -- * Session
    Session (Session),
    runSessionIO,
    withSession,

    -- ** Logging
    logError,

    -- ** Service Methods
    askMethod,
    askMethodKey,

    -- ** Topics
    askMethodTopic,
    askRequestTopic,
    askResponseTopic,

    -- ** Filters
    askRequestFilter,
    askControlFilter,

    -- * Session Handles
    SessionHandle
      ( SessionHandle,
        hdlThread,
        hdlRqtChan,
        hdlHeartbeat
      ),

    -- ** Session Watchdog
    defaultWatchdogPeriodSec,
    newWatchdogIO,

    -- * Session Config
    SessionConfig
      ( SessionConfig,
        cfgClient,
        cfgSessions,
        cfgLogger,
        cfgTopics,
        cfgMsgSize,
        cfgMethods
      ),
    insertSessionM,
    lookupSessionM,
    deleteSessionM,

    -- * Session Topics
    SessionTopic
      ( SessionTopic,
        topicBase,
        topicSid,
        topicSvc,
        topicRpc
      ),

    -- ** Topics
    fromRqtTopic,
  )
where

----------------------------------------------------------------------------------

import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async

import Control.Concurrent.STM.TChan (TChan, newTChanIO)

import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)

import Data.Time.Clock (NominalDiffTime)

import Data.HashMap.Strict qualified as HashMap
import Data.List (stripPrefix)

import Language.Haskell.TH.Syntax (Name)
import Language.Haskell.TH.Syntax qualified as TH.Syntax

import Network.MQTT.Client (MQTTClient)
import Network.MQTT.Topic (Filter, Topic)
import Network.MQTT.Topic qualified as Topic

import UnliftIO.Exception (finally)

import Relude

import System.Timeout qualified as System

----------------------------------------------------------------------------------

import Control.Concurrent.TMap (TMap)
import Control.Concurrent.TMap qualified as TMap

import Network.GRPC.MQTT.Logging (Logger)
import Network.GRPC.MQTT.Logging qualified as Logging
import Network.GRPC.MQTT.Topic qualified as Topic
import Network.GRPC.MQTT.Types (ClientHandler, MethodMap)

-- Session ----------------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
newtype Session a = Session
  {unSession :: ReaderT SessionConfig IO a}
  deriving
    (Functor, Applicative, Monad)
    via ReaderT SessionConfig IO
  deriving
    (MonadIO, MonadUnliftIO, MonadReader SessionConfig)
    via ReaderT SessionConfig IO

-- | Evaluates a 'Session' with the given 'SessionConfig'.
--
-- @since 0.1.0.0
runSessionIO :: Session a -> SessionConfig -> IO a
runSessionIO session = runReaderT (unSession session)

-- | Lexically scoped session handler.
--
--   * If the ambient session id is not a member of the sessions map, a new
--     'SessionHandle' is created, assigned to the session id, and provided to
--     the inner function.
--
--   * If the ambient session id already has an associated 'SessionHandle', then
--     that session handle is provided to the inner function.
--
-- The 'SessionHandle' created by 'withSession' is freed from the sessions map
-- after the inner function's timeout period expires or yields a result.
--
-- @since 0.1.0.0
withSession :: (SessionHandle -> Session ()) -> Session ()
withSession k = do
  config <- ask
  let sessionKey = topicSid (cfgTopics config)
  withRunInIO \runIO -> do
    rec handle <- newSessionHandleIO thread
        thread <- Async.async $ runIO do
          insertSessionM sessionKey handle
          finally (k handle) (deleteSessionM sessionKey)
    pure ()

-- | Querys the ambient sessions map for session with the given session id
-- 'Topic'.
--
-- @since 0.1.0.0
lookupSessionM :: Topic -> Session (Maybe SessionHandle)
lookupSessionM sid = do
  sessions <- asks cfgSessions
  liftIO (atomically (TMap.lookup sid sessions))

-- | Registers a new 'SessionHandle' with the given session id 'Topic' with the
-- ambient sessions map.
--
-- @since 0.1.0.0
insertSessionM :: Topic -> SessionHandle -> Session ()
insertSessionM sid handle = do
  sessions <- asks cfgSessions
  liftIO (atomically (TMap.insert sid handle sessions))

-- | Frees the 'SessionHandle' with the given session id 'Topic' from the ambient
-- sessions map, if one exists.
--
-- @since 0.1.0.0
deleteSessionM :: Topic -> Session ()
deleteSessionM sid = do
  sessions <- asks cfgSessions
  liftIO (atomically (TMap.delete sid sessions))

-- Session - Logging ------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
logError :: (MonadReader SessionConfig m, MonadIO m) => Name -> Text -> m ()
logError name msg = do
  logger <- asks cfgLogger
  let qname :: Text
      qname = case TH.Syntax.nameModule name of
        Nothing -> toText (TH.Syntax.nameBase name)
        Just xs -> toText (xs ++ "." ++ TH.Syntax.nameBase name)
   in Logging.logErr logger (qname <> ": " <> msg)

-- 'Session' ---------------------------------------------------------------------

-- $session-methods

-- | Queries the session's method map for the 'ClientHandler' mapped to the
-- session's service and RPC name.
--
-- @since 0.1.0.0
askMethod :: Session (Maybe ClientHandler)
askMethod =
  HashMap.lookup
    <$> askMethodKey
    <*> asks cfgMethods

-- | TODO
--
-- @since 0.1.0.0
askMethodKey :: Session ByteString
askMethodKey = do
  -- 'askMethodTopic' renders the topic as "service/rpc", but a session's
  -- 'MethodMap' maps 'ByteString' keys of the form:
  --
  -- prop> askMethodKey ~ pure "/service/rpc"
  topic <- Topic.unTopic <$> askMethodTopic
  pure ("/" <> encodeUtf8 topic)

-- Session - MQTT Topics --------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
askMethodTopic :: Session Topic
askMethodTopic =
  Topic.makeRPCMethodTopic
    <$> asks (topicSvc . cfgTopics)
    <*> asks (topicRpc . cfgTopics)

-- | TODO
--
-- @since 0.1.0.0
askRequestTopic :: Session Topic
askRequestTopic =
  Topic.makeRequestTopic
    <$> asks (topicBase . cfgTopics)
    <*> asks (topicSid . cfgTopics)
    <*> asks (topicSvc . cfgTopics)
    <*> asks (topicRpc . cfgTopics)

-- | TODO
--
-- @since 0.1.0.0
askResponseTopic :: Session Topic
askResponseTopic =
  Topic.makeResponseTopic
    <$> asks (topicBase . cfgTopics)
    <*> asks (topicSid . cfgTopics)

-- Session - MQTT Filters -------------------------------------------------------

-- | Like 'makeControlFilter', but uses the base topic provided by session's
-- ambient 'SessionConfig'.
--
-- @since 0.1.0.0
askControlFilter :: Session Filter
askControlFilter = Topic.makeControlFilter <$> asks (topicBase . cfgTopics)

-- | Like 'makeRequestFilter', but uses the base topic provided by session's
-- ambient 'SessionConfig'.
--
-- @since 0.1.0.0
askRequestFilter :: Session Filter
askRequestFilter = Topic.makeRequestFilter <$> asks (topicBase . cfgTopics)

-- SessionHandle ----------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
data SessionHandle = SessionHandle
  { hdlThread :: Async ()
  , hdlRqtChan :: TChan LByteString
  , hdlHeartbeat :: TMVar ()
  }

-- | The default watchdog timeout period in seconds.
--
-- >>> defaultWatchdogPeriodSec
-- 10s
--
-- @since 0.1.0.0
defaultWatchdogPeriodSec :: NominalDiffTime
defaultWatchdogPeriodSec = 10

-- | Constructs a 'SessionHandle' monitoring from a request handler thread.
--
-- @since 0.1.0.0
newSessionHandleIO :: Async () -> IO SessionHandle
newSessionHandleIO thread = do
  channel <- newTChanIO
  monitor <- newTMVarIO ()
  pure (SessionHandle thread channel monitor)

-- | TODO
--
-- @since 0.1.0.0
newWatchdogIO :: NominalDiffTime -> TMVar () -> IO ()
newWatchdogIO period'sec var = do
  -- 'NominalDiffTime' is measured in unit-seconds. Here @period'sec@ is converted
  -- to microseconds (1/10^6 seconds) to be compatible with 'System.timeout'.
  let period'usec :: NominalDiffTime
      period'usec = period'sec * 1e6
   in heartbeatIO (floor period'usec) var
  where
    heartbeatIO :: Int -> TMVar () -> IO ()
    heartbeatIO usec x = do
      signal <- System.timeout usec do
        atomically (takeTMVar x)
      case signal of
        Nothing -> pure ()
        Just () -> heartbeatIO usec x

-- SessionConfig ----------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
data SessionConfig = SessionConfig
  { cfgClient :: MQTTClient
  , cfgSessions :: TMap Topic SessionHandle
  , cfgLogger :: Logger
  , cfgTopics :: {-# UNPACK #-} !SessionTopic
  , cfgMsgSize :: {-# UNPACK #-} !Int
  , cfgMethods :: MethodMap
  }
  deriving (Generic)

-- SessionTopic -----------------------------------------------------------------

-- | The 'SessionTopic' is a collection of single-level topics used by remote
-- client sessions. 'SessionTopic' conversion functions (such as 'toRqtTopic') can
-- be used to deconstruct a 'SessionTopic' into frequently used MQTT topic.
--
-- @since 0.1.0.0
data SessionTopic = SessionTopic
  { topicBase :: {-# UNPACK #-} !Topic
  , topicSid :: {-# UNPACK #-} !Topic
  , topicSvc :: {-# UNPACK #-} !Topic
  , topicRpc :: {-# UNPACK #-} !Topic
  }
  deriving (Eq, Generic, Show)

-- SessionTopic -----------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
fromRqtTopic :: Topic -> Topic -> Maybe SessionTopic
fromRqtTopic base topic = do
  ["grpc", "request", sid, svc, rpc] <- stripPrefix (Topic.split base) (Topic.split topic)
  pure (SessionTopic base sid svc rpc)
