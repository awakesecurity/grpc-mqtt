-- Copyright (c) 2021-2022 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE TemplateHaskell #-}

-- |
module Network.GRPC.MQTT.TH.Client
  ( Batched (Batched, Unbatched),
    MethodName (MethodName),
    mqttClientFuncs,
    mqttRequest,
  )
where

import Relude

import Network.GRPC.MQTT.TH.Proto (forEachService)

import Language.Haskell.TH
  ( Dec,
    DecsQ,
    Name,
    Q,
    appE,
    clause,
    conE,
    conT,
    funD,
    mkName,
    normalB,
    sigD,
    varE,
    varP,
  )
import Network.GRPC.HighLevel (MethodName (MethodName))
import Network.GRPC.MQTT.Client (MQTTGRPCClient, mqttRequest)
import Network.GRPC.MQTT.Types
  ( Batched (Batched, Unbatched),
    MQTTRequest,
    MQTTResult,
  )
import Network.MQTT.Topic (Topic)
import Proto3.Suite.DotProto.Internal.Compat (prefixedMethodName)
import Turtle (FilePath)

--------------------------------------------------------------------------------

mqttClientFuncs :: Turtle.FilePath -> Batched -> Q [Dec]
mqttClientFuncs fp defaultBatchedStream = fmap concat $
  forEachService fp defaultBatchedStream $ \serviceName serviceMethods -> do
    clientFuncName <- mkName <$> prefixedMethodName serviceName "MqttClient"
    lift $ clientService clientFuncName (mkName serviceName) [(a, batched) | (a, batched, _, _) <- serviceMethods]

clientService :: Name -> Name -> [(String, Batched)] -> DecsQ
clientService fname serviceName methods = do
  fSig <- sigD fname [t|MQTTGRPCClient -> Topic -> $(conT serviceName) MQTTRequest MQTTResult|]
  fDef <- funD fname [clause args (normalB mqttClientE) []]
  return [fSig, fDef]
  where
    clientName = mkName "client"
    clientE = varE clientName
    topicName = mkName "baseTopic"
    topicE = varE topicName
    args = [varP clientName, varP topicName]

    mqttRequestE (methodName, batched) = [e|(mqttRequest $clientE $topicE (MethodName methodName) batched)|]
    clientMethods = mqttRequestE <$> methods
    mqttClientE = foldl' appE (conE serviceName) clientMethods
