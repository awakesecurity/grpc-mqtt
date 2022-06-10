{-# LANGUAGE ImportQualifiedPost #-}

-- | This module exports templates for constructing frequently MQTT topics and
-- filters that are frequently needed by clients and remote clients.
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Topic
  ( -- * MQTT Topic Templates
    -- $mqtt-topic-templates
    makeRPCMethodTopic,
    makeControlTopic,
    makeRequestTopic,
    makeResponseTopic,

    -- * MQTT Filter Templates
    -- $mqtt-filter-templates
    makeControlFilter,
    makeRequestFilter,

    -- * Re-exports
    Topic (unTopic),
    Filter (unFilter),
  )
where

---------------------------------------------------------------------------------

import Network.MQTT.Topic (Filter (unFilter), Topic (unTopic))
import Network.MQTT.Topic qualified as Topic

import Relude

-- MQTT Topics ------------------------------------------------------------------

-- $mqtt-topic-templates
--
-- Functions for constructing frequently needed MQTT topics used by clients and
-- remote client.

-- | Constructs a topic from the given base topic and RPC method name.
--
-- >>> makeRPCMethodTopic "service.Name" "rpc.Method"
-- Topic {unTopic = "service.Name/rpc.Method"}
--
-- @since 0.1.0.0
makeRPCMethodTopic :: Topic -> Topic -> Topic
makeRPCMethodTopic svc rpc = svc <> rpc

-- | Constructs a session's control topic for a given base topic and session ID.
--
-- >>> -- Using the session ID "i1X-Kk7cjUkpeEswPfP9kIid"...
-- >>> makeControlTopic "base.topic" "i1X-Kk7cjUkpeEswPfP9kIid"
-- Topic {unTopic = "base.topic/grpc/session/i1X-Kk7cjUkpeEswPfP9kIid/control"}
--
-- @since 0.1.0.0
makeControlTopic :: Topic -> Topic -> Topic
makeControlTopic base sid = makeResponseTopic base sid <> "control"

-- | Constructs a session's request topic for a given base topic, session ID,
-- service name, and RPC method name.
--
-- >>> -- Using the session ID "cFCQLYSWNprWkMEWsRcbl1yx"...
-- >>> makeRequestTopic "base" "cFCQLYSWNprWkMEWsRcbl1yx" "my.service" "my.method"
-- Topic {unTopic = "base/grpc/request/cFCQLYSWNprWkMEWsRcbl1yx/my.service/my.method"}
--
-- @since 0.1.0.0
makeRequestTopic :: Topic -> Topic -> Topic -> Topic -> Topic
makeRequestTopic base sid svc rpc = base <> "grpc" <> "request" <> sid <> svc <> rpc

-- | Constructs a session response topic from the given base topic and session
-- ID.
--
-- >>> -- Using the session ID "i1X-Kk7cjUkpeEswPfP9kIid"...
-- >>> makeResponseTopic "base.topic" "i1X-Kk7cjUkpeEswPfP9kIid"
-- Topic {unTopic = "base.topic/grpc/session/i1X-Kk7cjUkpeEswPfP9kIid"}
--
-- @since 0.1.0.0
makeResponseTopic :: Topic -> Topic -> Topic
makeResponseTopic base sid = base <> "grpc" <> "session" <> sid

-- MQTT Filters -----------------------------------------------------------------

-- $mqtt-filter-templates
--
-- Functions for constructing frequently needed MQTT filters used by clients and
-- remote client.

-- | Constructs a MQTT filter used to filter a session's auxiliary control
-- messages for a given base topic.
--
-- >>> makeControlFilter "base.topic"
-- Filter {unFilter = "base.topic/grpc/session/+/control"}
--
-- >>> makeControlFilter ("two" <> "level")
-- Filter {unFilter = "two/levels/grpc/session/+/control"}
--
-- @since 0.1.0.0
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
-- @since 0.1.0.0
makeRequestFilter :: Topic -> Filter
makeRequestFilter base = Topic.toFilter base <> "grpc" <> "request" <> "+" <> "+" <> "+"
