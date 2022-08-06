-- Copyright (c) 2021-2022 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE TemplateHaskell #-}

module Network.GRPC.MQTT.TH.RemoteClient
  ( Client,
    MethodMap,
    mqttRemoteClientMethodMap,
    wrapServerStreamingClientHandler,
    wrapUnaryClientHandler,
  )
where

import Network.GRPC.HighLevel.Client (Client)

import Proto3.Suite.DotProto.Internal.Compat (prefixedMethodName)

import Language.Haskell.TH
  ( Dec,
    DecsQ,
    ExpQ,
    Name,
    Q,
    clause,
    funD,
    listE,
    mkName,
    normalB,
    sigD,
    varE,
    varP,
  )

import Relude

import Turtle (FilePath)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.TH.Proto (forEachService)
import Network.GRPC.MQTT.Types (MethodMap)
import Network.GRPC.MQTT.Wrapping
  ( wrapServerStreamingClientHandler,
    wrapUnaryClientHandler,
  )

--------------------------------------------------------------------------------

mqttRemoteClientMethodMap :: Turtle.FilePath -> Q [Dec]
mqttRemoteClientMethodMap fp = fmap concat $
  forEachService fp \serviceName serviceMethods -> do
    clientFuncName <- mkName <$> prefixedMethodName serviceName "RemoteClientMethodMap"
    grpcClientName <- mkName <$> prefixedMethodName serviceName "Client"
    lift $ rcMethodMap clientFuncName grpcClientName serviceMethods

rcMethodMap :: Name -> Name -> [(String, ExpQ, Name)] -> DecsQ
rcMethodMap fname grpcName methods = do
  fSig <- sigD fname [t|Client -> IO MethodMap|]
  fDef <- funD fname [clause args (normalB methodMapE) []]
  return [fSig, fDef]
  where
    clientName = mkName "grpcClient"
    clientE = varE clientName
    args = [varP clientName]
    clientVarName = mkName "client"
    methodPairs = fmap (\(method, wrapFun, clientFun) -> [e|(method, $wrapFun ($(varE clientFun) $(varE clientVarName)))|]) methods
    methodMapE =
      [e|
        do
          $(varP clientVarName) <- $(varE grpcName) $clientE
          return $ fromList $(listE methodPairs)
        |]
