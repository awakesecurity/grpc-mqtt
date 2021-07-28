{- 
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}

{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TemplateHaskell #-}

module Test.ProtoClients where

import Network.GRPC.MQTT.TH.Client
import Proto.Test

-- addHelloMqttClient :: MQTTGRPCClient -> Topic -> AddHello MQTTRequest MQTTResult
-- addHelloMqttClient client baseTopic =
--   AddHello
--     (mqttRequest client baseTopic (MethodName "/test.AddHello/Add"))
--     (mqttRequest client baseTopic (MethodName "/test.AddHello/HelloSS"))

-- multGoodbyeMqttClient :: MQTTGRPCClient -> Topic -> MultGoodbye MQTTRequest MQTTResult
-- multGoodbyeMqttClient client baseTopic =
--   MultGoodbye
--     (mqttRequest client baseTopic (MethodName "/test.MultGoodbye/Mult"))
--     (mqttRequest client baseTopic (MethodName "/test.MultGoodbye/GoodbyeSS"))

$(mqttClientFuncs "proto/test.proto")
