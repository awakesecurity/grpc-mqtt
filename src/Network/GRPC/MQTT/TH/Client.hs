{-# LANGUAGE TemplateHaskell #-}

module Network.GRPC.MQTT.TH.Client (
  mqttClientFuncs,
  mqttRequest,
  MethodName (MethodName),
) where

import Relude hiding (FilePath)

import Network.GRPC.MQTT.TH.Proto (forEachService)

import Language.Haskell.TH (
  Dec,
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
import Network.GRPC.MQTT.Client (
  MQTTGRPCClient,
  mqttRequest,
 )
import Network.GRPC.MQTT.Types (MQTTRequest, MQTTResult)
import Network.MQTT.Topic (Topic)
import Proto3.Suite.DotProto.Internal (prefixedFieldName)
import Turtle (FilePath)

mqttClientFuncs :: FilePath -> Q [Dec]
mqttClientFuncs fp = fmap concat $
  forEachService fp $ \serviceName serviceMethods -> do
    clientFuncName <- mkName <$> prefixedFieldName serviceName "mqttClient"
    lift $ clientService clientFuncName (mkName serviceName) [a | (a, _, _) <- serviceMethods]

clientService :: Name -> Name -> [String] -> DecsQ
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

  methodNames = fmap (\ep -> [e|MethodName ep|]) methods
  mqttRequestE methodName = [e|(mqttRequest $clientE $topicE $methodName)|]
  clientMethods = mqttRequestE <$> methodNames
  mqttClientE = foldl' appE (conE serviceName) clientMethods
