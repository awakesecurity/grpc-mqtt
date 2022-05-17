{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.Topic
  ( -- * MQTT Topics
    makeRPCMethodTopic,
    makeRequestTopic,
    makeResponseTopic,

    -- * MQTT Filters
    makeControlFilter,
    makeRequestFilter,
  )
where

---------------------------------------------------------------------------------

import Network.MQTT.Topic (Filter, Topic)
import Network.MQTT.Topic qualified as Topic

-- MQTT Topics ------------------------------------------------------------------

-- | Constructs a session response topic from the given base topic and session
-- id.
--
-- >>> makeRPCMethodTopic "service.Name" "rpc.Method"
-- Topic {unTopic = "service.Name/rpc.Method"}
--
-- @since 1.0.0
makeRPCMethodTopic :: Topic -> Topic -> Topic
makeRPCMethodTopic svc rpc = svc <> rpc

-- | Renders a 'SessionTopic' as the session's request MQTT topic.
--
-- >>> makeRequestTopic "base" "cFCQLYSWNprWkMEWsRcbl1yx" "my.service" "my.method"
-- Topic {unTopic = "base/grpc/request/cFCQLYSWNprWkMEWsRcbl1yx/my.service/my.method"}
--
-- @since 1.0.0
makeRequestTopic :: Topic -> Topic -> Topic -> Topic -> Topic
makeRequestTopic base sid svc rpc = base <> "grpc" <> "request" <> sid <> svc <> rpc

-- | Constructs a session response topic from the given base topic and session
-- id.
--
-- >>> makeResponseTopic "base.topic" "i1X-Kk7cjUkpeEswPfP9kIid"
-- Topic {unTopic = "base.topic/grpc/session/i1X-Kk7cjUkpeEswPfP9kIid"}
--
-- @since 1.0.0
makeResponseTopic :: Topic -> Topic -> Topic
makeResponseTopic base sid = base <> "grpc" <> "session" <> sid

-- MQTT Filters -----------------------------------------------------------------

-- | Constructs a MQTT filter used to filter a session's auxiliary control
-- messages for a given base topic.
--
-- >>> makeControlFilter "base.topic"
-- Filter {unFilter = "base.topic/grpc/session/+/control"}
--
-- >>> makeControlFilter ("two" <> "level")
-- Filter {unFilter = "two/levels/grpc/session/+/control"}
--
-- @since 1.0.0
makeControlFilter :: Topic -> Filter
makeControlFilter base = Topic.toFilter base <> "grpc" <> "session" <> "+" <> "control"

-- | Constructs a MQTT filter used to filter a session's request messages for a
-- given base topic.
--
-- >>> makeRequestFilter "base.topic"
-- Filter {unFilter = "base.topic/grpc/request/+/+/+"}
--
-- >>> makeRequestFilter ("two" <> "level")
-- Filter {unFilter = "two/levels/grpc/request/+/+/+"}
--
-- @since 1.0.0
makeRequestFilter :: Topic -> Filter
makeRequestFilter base = Topic.toFilter base <> "grpc" <> "request" <> "+" <> "+" <> "+"
