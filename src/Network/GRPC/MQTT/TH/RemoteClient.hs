{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE TemplateHaskell #-}

module Network.GRPC.MQTT.TH.RemoteClient
  ( Batched (..),
    Client,
    MethodMap,
    mqttRemoteClientMethodMap,
    wrapServerStreamingClientHandler,
    wrapUnaryClientHandler,
  )
where

import Network.GRPC.MQTT.TH.Proto (forEachService)

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
import Network.GRPC.HighLevel.Client (Client)
import Network.GRPC.MQTT.Types (Batched (..), MethodMap)
import Network.GRPC.MQTT.Wrapping (wrapServerStreamingClientHandler, wrapUnaryClientHandler)
import Proto3.Suite.DotProto.Internal (prefixedFieldName)
import Turtle (FilePath)

--------------------------------------------------------------------------------

mqttRemoteClientMethodMap :: Turtle.FilePath -> Batched -> Q [Dec]
mqttRemoteClientMethodMap fp defaultBatchedStream = fmap concat $
  forEachService fp defaultBatchedStream $ \serviceName serviceMethods -> do
    clientFuncName <- mkName <$> prefixedFieldName serviceName "remoteClientMethodMap"
    grpcClientName <- mkName <$> prefixedFieldName serviceName "client"
    lift $ rcMethodMap clientFuncName grpcClientName serviceMethods

rcMethodMap :: Name -> Name -> [(String, Batched, ExpQ, Name)] -> DecsQ
rcMethodMap fname grpcName methods = do
  fSig <- sigD fname [t|Client -> IO MethodMap|]
  fDef <- funD fname [clause args (normalB methodMapE) []]
  return [fSig, fDef]
  where
    clientName = mkName "grpcClient"
    clientE = varE clientName
    args = [varP clientName]
    clientVarName = mkName "client"
    methodPairs =
      fmap
        (\(method, _, wrapFun, clientFun) -> [e|(method, $wrapFun ($(varE clientFun) $(varE clientVarName)))|])
        methods
    methodMapE =
      [e|
        do
          $(varP clientVarName) <- $(varE grpcName) $clientE
          return $ fromList $(listE methodPairs)
        |]
