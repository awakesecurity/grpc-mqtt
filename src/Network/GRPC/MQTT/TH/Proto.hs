{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.GRPC.MQTT.TH.Proto where

import Relude hiding (FilePath)

import Network.GRPC.MQTT.Wrapping (
  wrapClientStreamingClientHandler,
  wrapServerStreamingClientHandler,
  wrapUnaryClientHandler,
 )

import Language.Haskell.TH (Name, Q, mkName)
import Proto3.Suite.DotProto.AST (
  DotProto (protoDefinitions, protoPackage),
  DotProtoDefinition (DotProtoService),
  DotProtoIdentifier (Single),
  DotProtoServicePart (DotProtoServiceRPCMethod),
  RPCMethod (
    RPCMethod,
    rpcMethodName,
    rpcMethodOptions,
    rpcMethodRequestStreaming,
    rpcMethodRequestType,
    rpcMethodResponseStreaming,
    rpcMethodResponseType
  ),
  Streaming (NonStreaming, Streaming),
 )
import Proto3.Suite.DotProto.Internal (
  CompileError,
  dpIdentQualName,
  dpIdentUnqualName,
  importProto,
  invalidMethodNameError,
  prefixedFieldName,
  protoPackageName,
  typeLikeName,
  _unimplementedError,
 )
import Turtle (FilePath, directory, filename)

forEachService :: FilePath -> (String -> [(String, Name, Name)] -> ExceptT CompileError Q a) -> Q [a]
forEachService protoFilepath action =
  either (fail . show) pure
    =<< runExceptT
      ( do
          let protoFile = filename protoFilepath
              protoDir = directory protoFilepath

          dotproto <- importProto [protoDir] protoFile protoFile
          packageName <- dpIdentQualName =<< protoPackageName (protoPackage dotproto)

          let services = [(name, parts) | DotProtoService _ name parts <- protoDefinitions dotproto]

          forM services $ \(name, parts) -> do
            serviceName <- typeLikeName =<< dpIdentUnqualName name
            let endpointPrefix = "/" <> packageName <> "." <> serviceName <> "/"

            let serviceMethodName (DotProtoServiceRPCMethod RPCMethod{..}) = do
                  case rpcMethodName of
                    Single nm -> do
                      streamingWrapper <-
                        case (rpcMethodRequestStreaming, rpcMethodResponseStreaming) of
                          (NonStreaming, Streaming) -> pure 'wrapServerStreamingClientHandler
                          (NonStreaming, NonStreaming) -> pure 'wrapUnaryClientHandler
                          (Streaming, NonStreaming) -> pure 'wrapClientStreamingClientHandler
                          _ -> _unimplementedError "Bidirectional streaming not supported"
                      clientFun <- prefixedFieldName serviceName nm
                      return [(endpointPrefix <> nm, streamingWrapper, mkName clientFun)]
                    _ -> invalidMethodNameError rpcMethodName
                serviceMethodName _ = pure []

            serviceMethods <- foldMapM serviceMethodName parts
            action serviceName serviceMethods
      )
