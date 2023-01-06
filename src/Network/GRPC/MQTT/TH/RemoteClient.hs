{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      :  Network.GRPC.MQTT.TH.RemoteClient
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see LICENSE
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- @since 1.0.0
module Network.GRPC.MQTT.TH.RemoteClient
  ( Client,
    MethodMap,
    mqttRemoteClientMethodMap,
  )
where

import Network.GRPC.LowLevel (GRPCMethodType (..))
import Network.GRPC.LowLevel.Client
  ( Client,
    clientRW,
    clientReader,
    clientRegisterMethodBiDiStreaming,
    clientRegisterMethodClientStreaming,
    clientRegisterMethodNormal,
    clientRegisterMethodServerStreaming,
    clientRequest,
    clientWriter,
  )

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

import Network.GRPC.MQTT.TH.Proto (forEachService)
import Network.GRPC.MQTT.Types (ClientHandler (..), MethodMap, RemoteResult (..))

--------------------------------------------------------------------------------

mqttRemoteClientMethodMap :: Turtle.FilePath -> Q [Dec]
mqttRemoteClientMethodMap fp =
  concat <$> forEachService fp \serviceName serviceMethods -> do
    clientFuncName <- mkName <$> prefixedMethodName serviceName "RemoteClientMethodMap"
    lift $ rcMethodMap clientFuncName serviceMethods

rcMethodMap :: Name -> [(String, GRPCMethodType)] -> DecsQ
rcMethodMap fname methods = do
  let clientName = mkName "grpcClient"
      clientVarE = varE clientName
      args = [varP clientName]
      regMethodVarName = mkName "registeredMethod"
      regMethodVarE = varE regMethodVarName

  -- Type of generated code: IO (ByteString, ClientHandler)
  let mkMethodPair :: (String, GRPCMethodType) -> ExpQ
      mkMethodPair (methodName, methodType) = do
        let (registerFun, handlerFun) =
              case methodType of
                Normal ->
                  ( [e|clientRegisterMethodNormal|]
                  , [e|
                      ClientUnaryHandler \req timeout metadata ->
                        fmap
                          (either RemoteErrorResult RemoteNormalResult)
                          (clientRequest $clientVarE $regMethodVarE timeout req metadata)
                      |]
                  )
                ClientStreaming ->
                  ( [e|clientRegisterMethodClientStreaming|]
                  , [e|
                      ClientClientStreamHandler \timeout metadata hdlr ->
                        fmap
                          (either RemoteErrorResult RemoteWriterResult)
                          (clientWriter $clientVarE $regMethodVarE timeout metadata hdlr)
                      |]
                  )
                ServerStreaming ->
                  ( [e|clientRegisterMethodServerStreaming|]
                  , [e|
                      ClientServerStreamHandler \req timeout metadata hdlr ->
                        fmap
                          (either RemoteErrorResult RemoteReaderResult)
                          (clientReader $clientVarE $regMethodVarE timeout req metadata hdlr)
                      |]
                  )
                BiDiStreaming ->
                  ( [e|clientRegisterMethodBiDiStreaming|]
                  , [e|
                      ClientBiDiStreamHandler \timeout metadata hdlr ->
                        fmap
                          (either RemoteErrorResult RemoteBiDiResult)
                          (clientRW $clientVarE $regMethodVarE timeout metadata hdlr)
                      |]
                  )
        [e|
          do
            $(varP regMethodVarName) <- $registerFun $clientVarE methodName
            pure (methodName, $handlerFun)
          |]

  -- Type of generated code: [IO (ByteString, ClientHandler)]
  let methodPairs :: [ExpQ]
      methodPairs = fmap mkMethodPair methods

  let methodMapE =
        [e|
          do
            fromList <$> sequenceA $(listE methodPairs)
          |]

  fSig <- sigD fname [t|Client -> IO MethodMap|]
  fDef <- funD fname [clause args (normalB methodMapE) []]
  return [fSig, fDef]
