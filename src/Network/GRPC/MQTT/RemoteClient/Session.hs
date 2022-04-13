{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecursiveDo #-}

-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.RemoteClient.Session
  ( -- * SessionManager
    SessionManager (..),
    runSessionManager,
    lookupSession,
    insertSession,
    deleteSession,

    -- * Session
    Session (..),
    newSession,
    newSessionWatchdog,

    -- * Session Maps
    SessionMap,
    newSessionMap,
    lookupSessionMap,
    insertSessionMap,
    deleteSessionMap,

    -- * Session Contexts
    SessionCtx (..),
    sessionTopic,
  )
where

---------------------------------------------------------------------------------

import Data.Map.Strict qualified as Map

import Network.MQTT.Client (MQTTClient)
import Network.MQTT.Topic (Topic (..))
import Network.GRPC.MQTT.Core (heartbeatPeriodSeconds)

import Turtle (NominalDiffTime)

import UnliftIO (TChan, finally, newTChanIO, race_, timeout)
import UnliftIO.Async (Async, async)

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Logging (Logger, logWarn)
import Network.GRPC.MQTT.Types (MethodMap, SessionId)

-- Session Manager ---------------------------------------------------------------------

newtype SessionManager a = SessionManager
  {unSessionManager :: ReaderT SessionCtx IO a}
  deriving
    (Functor, Applicative, Monad, MonadIO, MonadReader SessionCtx)
    via ReaderT SessionCtx IO

-- | TODO
--
-- @since 1.0.0
runSessionManager :: SessionManager a -> SessionCtx -> IO a
runSessionManager (SessionManager m) = runReaderT m

-- | TODO
--
-- @since 1.0.0
lookupSession :: SessionId -> SessionManager (Maybe Session)
lookupSession sid = do
  sessionMap <- asks sessCtxSessionMap
  liftIO (lookupSessionMap sid sessionMap)

-- | TODO
--
-- @since 1.0.0
insertSession :: SessionId -> Session -> SessionManager ()
insertSession sid session = do
  sessionMap <- asks sessCtxSessionMap
  liftIO (insertSessionMap sid session sessionMap)

-- | TODO
--
-- @since 1.0.0
deleteSession :: SessionId -> SessionManager ()
deleteSession sid = do
  sessionMap <- asks sessCtxSessionMap
  liftIO (deleteSessionMap sid sessionMap)

-- Sessions ---------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
data Session = Session
  { sessHandlerThread :: Async ()
  , sessHeartbeatSem :: TMVar ()
  , sessRequestChan :: TChan LByteString
  }

-- | TODO
--
-- @since 1.0.0
newSession :: (Session -> SessionManager ()) -> SessionManager Session
newSession hdl = do
  sessctx <- ask
  session <- liftIO (newSessionIO sessctx)

  let sessionId :: SessionId
      sessionId = unTopic (sessCtxSessionId sessctx)
   in insertSession sessionId session

  pure session
  where
    newSessionIO :: SessionCtx -> IO Session
    newSessionIO ctx = do
      rec athread <- async (sessionHandler session ctx)
          session <- liftA2 (Session athread) (newTMVarIO ()) newTChanIO
      pure session

    sessionHandler :: Session -> SessionCtx -> IO ()
    sessionHandler session ctx = do
      let withMonitor :: IO ()
          withMonitor = race_ (sessionHeartbeat session ctx)
                              (runSessionManager (hdl session) ctx)

          sessionId :: SessionId
          sessionId = unTopic (sessCtxSessionId ctx)
       in finally withMonitor do
            runSessionManager (deleteSession sessionId) ctx

    sessionHeartbeat :: Session -> SessionCtx -> IO ()
    sessionHeartbeat session ctx = do
      newSessionWatchdog (1 + heartbeatPeriodSeconds) session
      let logger :: Logger
          logger = sessCtxLogger ctx

          logsid :: Text
          logsid = unTopic (sessCtxSessionId ctx)

          logmsg :: Text
          logmsg = "session ID #" <> logsid <> ": watchdog timed out."

       in logWarn logger logmsg

-- | TODO
--
-- @since 1.0.0
newSessionWatchdog :: NominalDiffTime -> Session -> IO ()
newSessionWatchdog timelimit sess = loop
  where
    uSecs :: Int
    uSecs = floor (timelimit * 1_000_000)

    loop :: IO ()
    loop = do
      result <- timeout uSecs do
        let sem :: TMVar ()
            sem = sessHeartbeatSem sess
         in atomically (takeTMVar sem)
      case result of
        Nothing -> pure ()
        Just () -> loop

-- SessionMap -------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
type SessionMap = TVar (Map SessionId Session)

-- | TODO
--
-- @since 1.0
newSessionMap :: IO SessionMap
newSessionMap = newTVarIO Map.empty

-- | TODO
--
-- @since 1.0.0
lookupSessionMap :: SessionId -> SessionMap -> IO (Maybe Session)
lookupSessionMap sid sessionMap = atomically do
  xs <- readTVar sessionMap
  pure (Map.lookup sid xs)

-- | TODO
--
-- @since 1.0.0
insertSessionMap :: SessionId -> Session -> SessionMap -> IO ()
insertSessionMap sid session sessionMap = atomically do
  modifyTVar' sessionMap (Map.insert sid session)

-- | TODO
--
-- @since 1.0.0
deleteSessionMap :: SessionId -> SessionMap -> IO ()
deleteSessionMap sid sessionMap = atomically do
  modifyTVar' sessionMap (Map.delete sid)

-- SessionCtx -------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
data SessionCtx = SessionCtx
  { sessCtxLogger :: Logger
  , sessCtxSessionMap :: SessionMap
  , sessCtxClient :: MQTTClient
  , sessCtxMethodMap :: MethodMap
  , sessCtxBaseTopic :: Topic
  , sessCtxSessionId :: Topic
  , sessCtxMaxMsgSize :: Int
  , sessCtxGrpcMethod :: ByteString
  }

-- | TODO
--
-- @since 1.0.0
sessionTopic :: SessionCtx -> Topic
sessionTopic ctx = sessCtxBaseTopic ctx <> "grpc" <> "session" <> sessCtxSessionId ctx
