{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE ImplicitPrelude #-}

-- |
--
-- @since 1.0.0
module Network.GRPC.MQTT.RemoteClient.Session
  ( -- * Session
    Session (Session),
    runSessionIO,
    fixSession,

    -- ** Logging
    logError,

    -- ** Service Methods
    askMethod,
    askMethodKey,

    -- ** Topics
    askMethodTopic,
    askRqtTopic,
    askRspTopic,

    -- ** Filters
    askRqtFilter,
    askCtrlFilter,

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

    -- * Session Topics
    SessionTopic
      ( SessionTopic,
        topicBase,
        topicSid,
        topicSvc,
        topicRpc
      ),

    -- ** Topics & Filters
    toMethodTopic,
    fromRqtTopic,
    toRqtFilter,
    toRqtTopic,
    toRspTopic,
    toCtrlFilter,

    -- * Session Map
    SessionMap (SessionMap),
    getSessionMap,
    newSessionMapIO,
    insertSessionMap,
    lookupSessionMap,
    deleteSessionMap,
  )
where

----------------------------------------------------------------------------------

import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async

import Control.Concurrent.STM.TChan (TChan, newTChanIO)
import Control.Concurrent.STM.TMVar (TMVar, newTMVarIO, takeTMVar)
import Control.Concurrent.STM.TVar (TVar, modifyTVar', newTVarIO, readTVarIO)

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, ReaderT, ask, asks, runReaderT)
import Control.Monad.STM (atomically)

import Data.Kind (Type)
import Data.Time.Clock (NominalDiffTime)

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as Lazy (ByteString)
import Data.HashMap.Strict qualified as HashMap
import Data.List (stripPrefix)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding (encodeUtf8)

import GHC.Generics (Generic)

import Language.Haskell.TH.Syntax (Name)
import Language.Haskell.TH.Syntax qualified as TH.Syntax

import Network.MQTT.Client (MQTTClient)
import Network.MQTT.Topic (Filter, Topic)
import Network.MQTT.Topic qualified as Topic

import System.Timeout qualified as System

----------------------------------------------------------------------------------

import Network.GRPC.MQTT.Logging (Logger)
import Network.GRPC.MQTT.Logging qualified as Logging
import Network.GRPC.MQTT.Types (ClientHandler, MethodMap)

-- 'Session' ---------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
newtype Session (a :: Type) :: Type where
  Session :: {unSession :: ReaderT SessionConfig IO a} -> Session a
  deriving
    (Functor, Applicative, Monad, MonadIO, MonadReader SessionConfig)
    via ReaderT SessionConfig IO

-- | Evaluates a 'Session' with the given 'SessionConfig'.
--
-- @since 1.0.0
runSessionIO :: Session a -> SessionConfig -> IO a
runSessionIO session = runReaderT (unSession session)

-- | TODO
--
-- @since 1.0.0
fixSession :: (SessionHandle -> Session ()) -> Session ()
fixSession k = do
  config <- ask
  liftIO do
    let sessionKey = topicSid (cfgTopics config)
    let sessionMap = cfgSessions config

    -- Since the session handler @k@ is executed on a seperate thread, we can
    -- safely use recursive do here to construct a 'SessionHandle' which has a
    -- cyclic dependency on 'hdlThread' 'Async'.
    rec handle <- newSessionHandleIO thread
        thread <- Async.async do
          insertSessionMap sessionKey handle sessionMap
          runSessionIO (k handle) config
          deleteSessionMap sessionKey sessionMap
    pure ()

-- 'Session' ---------------------------------------------------------------------

-- $session-logging
--

-- | TODO
--
-- @since 1.0.0
logError :: (MonadReader SessionConfig m, MonadIO m) => Name -> Text -> m ()
logError name msg = do
  logger <- asks cfgLogger
  let qname :: Text
      qname = case TH.Syntax.nameModule name of
        Nothing -> Text.pack (TH.Syntax.nameBase name)
        Just xs -> Text.pack (xs ++ "." ++ TH.Syntax.nameBase name)
   in Logging.logErr logger (qname <> ": " <> msg)

-- 'Session' ---------------------------------------------------------------------

-- $session-methods
--

-- | Queries the session's method map for the 'ClientHandler' mapped to the
-- session's service and RPC name.
--
-- @since 1.0.0
askMethod :: Session (Maybe ClientHandler)
askMethod = HashMap.lookup <$> askMethodKey <*> asks cfgMethods

-- | TODO
--
-- @since 1.0.0
askMethodKey :: Session ByteString
askMethodKey = do
  -- 'askMethodTopic' renders the topic as "service/rpc", but a session's
  -- 'MethodMap' maps 'ByteString' keys of the form:
  --
  -- prop> askMethodKey ~ pure "/service/rpc"
  topic <- Topic.unTopic <$> askMethodTopic
  pure ("/" <> Text.Encoding.encodeUtf8 topic)

-- 'Session' ---------------------------------------------------------------------

-- $session-topics
--

-- | Like 'toMethodTopic', but uses the 'SessionTopic' provided by the session's
-- 'SessionConfig'.
--
-- @since 1.0.0
askMethodTopic :: Session Topic
askMethodTopic = asks (toMethodTopic . cfgTopics)

-- | Like 'toRqtTopic', but uses the 'SessionTopic' provided by the session's
-- 'SessionConfig'.
--
-- @since 1.0.0
askRqtTopic :: Session Topic
askRqtTopic = asks (toRqtTopic . cfgTopics)

-- | Like 'toRspTopic', but uses the 'SessionTopic' provided by the session's
-- 'SessionConfig'.
--
-- @since 1.0.0
askRspTopic :: Session Topic
askRspTopic = asks (toRspTopic . cfgTopics)

-- 'Session' ---------------------------------------------------------------------

-- $session-filters
--

-- | Like 'toCtrlFilter', but uses the 'SessionTopic' provided by the session's
-- 'SessionConfig'.
--
-- @since 1.0.0
askCtrlFilter :: Session Filter
askCtrlFilter = asks (toCtrlFilter . topicBase . cfgTopics)

-- | Like 'toRqtFilter', but uses the 'SessionTopic' provided by the session's
-- 'SessionConfig'.
--
-- @since 1.0.0
askRqtFilter :: Session Filter
askRqtFilter = asks (toRqtFilter . topicBase . cfgTopics)

-- 'SessionHandle' ---------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
data SessionHandle = SessionHandle
  { hdlThread :: Async ()
  , hdlRqtChan :: TChan Lazy.ByteString
  , hdlHeartbeat :: TMVar ()
  }

-- | The default watchdog timeout period in seconds.
--
-- >>> defaultWatchdogPeriodSec
-- 10s
--
-- @since 1.0.0
defaultWatchdogPeriodSec :: NominalDiffTime
defaultWatchdogPeriodSec = 10

-- | TODO
--
-- @since 1.0.0
newSessionHandleIO :: Async () -> IO SessionHandle
newSessionHandleIO thread = do
  SessionHandle thread
    <$> newTChanIO
    <*> newTMVarIO ()

-- | TODO
--
-- @since 1.0.0
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

-- 'SessionConfig' ---------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
data SessionConfig = SessionConfig
  { cfgClient :: MQTTClient
  , cfgSessions :: SessionMap
  , cfgLogger :: Logger
  , cfgTopics :: {-# UNPACK #-} !SessionTopic
  , cfgMsgSize :: {-# UNPACK #-} !Int
  , cfgMethods :: MethodMap
  }
  deriving (Generic)

-- 'SessionTopic' ----------------------------------------------------------------

-- | The 'SessionTopic' is a collection of single-level topics used by remote
-- client sessions. 'SessionTopic' conversion functions (such as 'toRqtTopic') can
-- be used to deconstruct a 'SessionTopic' into frequently used MQTT topic.
--
-- @since 1.0.0
data SessionTopic = SessionTopic
  { topicBase :: {-# UNPACK #-} !Topic
  , topicSid :: {-# UNPACK #-} !Topic
  , topicSvc :: {-# UNPACK #-} !Topic
  , topicRpc :: {-# UNPACK #-} !Topic
  }
  deriving (Eq, Generic, Show)

-- 'SessionTopic' ----------------------------------------------------------------
--
-- Conversion
--

-- | Renders the service topic (via 'topicSvc') and RPC method (via 'topicRpc')
-- name topics as the topic used for identifying a session's RPC method.
--
-- >>> toMethodTopic (SessionTopic "base" "badc0d3" "protosvc" "protorpc")
-- Topic {unTopic = "protosvc/protorpc"}
--
-- @since 1.0.0
toMethodTopic :: SessionTopic -> Topic
toMethodTopic (SessionTopic _ _ svc rpc) = svc <> rpc

-- | TODO
--
-- @since 1.0.0
fromRqtTopic :: Topic -> Topic -> Maybe SessionTopic
fromRqtTopic base topic = do
  ["grpc", "request", sid, svc, rpc] <- stripPrefix (Topic.split base) (Topic.split topic)
  pure (SessionTopic base sid svc rpc)

-- | Renders a 'SessionTopic' as the session's request MQTT topic filter.
--
-- >>> toRqtFilter "base"
-- Filter {unFilter = "base/grpc/request/+/+/+"}
--
-- @since 1.0.0
toRqtFilter :: Topic -> Filter
toRqtFilter base =
  Topic.toFilter base <> "grpc" <> "request" <> "+" <> "+" <> "+"

-- | Renders a 'SessionTopic' as the session's request MQTT topic.
--
-- >>> toRqtTopic (SessionTopic "base" "badc0d3" "protosvc" "protorpc")
-- Topic {unTopic = "base/grpc/request/badc0d3/protosvc/protorpc"}
--
-- @since 1.0.0
toRqtTopic :: SessionTopic -> Topic
toRqtTopic (SessionTopic base sid svc rpc) =
  base <> "grpc" <> "request" <> sid <> svc <> rpc

-- | Renders a 'SessionTopic' as the session's response MQTT topic.
--
-- >>> toRspTopic (SessionTopic "base" "badc0d3" "protosvc" "protorpc")
-- Topic {unTopic = "base/grpc/session/badc0d3"}
--
-- @since 1.0.0
toRspTopic :: SessionTopic -> Topic
toRspTopic (SessionTopic base sid _ _) =
  base <> "grpc" <> "session" <> sid

-- | Construct a MQTT topic filter subscribed to by sessions to recieve control
-- messages given a base MQTT topic for the filter to use.
--
-- >>> toCtrlFilter "base"
-- Filter {unFilter = "base/grpc/session/+/control"}
--
-- @since 1.0.0
toCtrlFilter :: Topic -> Filter
toCtrlFilter base =
  Topic.toFilter base <> "grpc" <> "session" <> "+" <> "control"

-- 'SessionMap' -----------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
newtype SessionMap = SessionMap
  {getSessionMap :: TVar (Map Topic SessionHandle)}

-- | TODO
--
-- @since 1.0
newSessionMapIO :: IO SessionMap
newSessionMapIO = SessionMap <$> newTVarIO Map.empty

-- | TODO
--
-- @since 1.0.0
lookupSessionMap :: Topic -> SessionMap -> IO (Maybe SessionHandle)
lookupSessionMap sid (SessionMap xs) =
  Map.lookup sid <$> readTVarIO xs

-- | TODO
--
-- @since 1.0.0
insertSessionMap :: Topic -> SessionHandle -> SessionMap -> IO ()
insertSessionMap sid session (SessionMap xs) =
  let adjust :: Map Topic SessionHandle -> Map Topic SessionHandle
      adjust = Map.insert sid session
   in atomically (modifyTVar' xs adjust)

-- | TODO
--
-- @since 1.0.0
deleteSessionMap :: Topic -> SessionMap -> IO ()
deleteSessionMap sid (SessionMap xs) =
  let adjust :: Map Topic SessionHandle -> Map Topic SessionHandle
      adjust = Map.delete sid
   in atomically (modifyTVar' xs adjust)
