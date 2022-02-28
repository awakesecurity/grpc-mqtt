-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
module Network.GRPC.MQTT.TH.Proto where

import Network.GRPC.MQTT.Wrapping
  ( wrapBiDiStreamingClientHandler,
    wrapClientStreamingClientHandler,
    wrapServerStreamingClientHandler,
    wrapUnaryClientHandler,
  )

import Language.Haskell.TH (ExpQ, Name, Q, mkName)
import Network.GRPC.MQTT.Types (Batched (Batched, Unbatched))
import Proto3.Suite.DotProto.AST
  ( DotProto (protoDefinitions, protoPackage),
    DotProtoDefinition (DotProtoService),
    DotProtoIdentifier (Single),
    DotProtoOption (dotProtoOptionIdentifier),
    DotProtoServicePart (DotProtoServiceOption, DotProtoServiceRPCMethod),
    DotProtoValue (BoolLit),
    RPCMethod
      ( RPCMethod,
        rpcMethodName,
        rpcMethodOptions,
        rpcMethodRequestStreaming,
        rpcMethodRequestType,
        rpcMethodResponseStreaming,
        rpcMethodResponseType
      ),
    Streaming (NonStreaming, Streaming),
    dotProtoOptionValue,
  )
import Proto3.Suite.DotProto.Internal
  ( CompileError,
    dpIdentQualName,
    dpIdentUnqualName,
    importProto,
    invalidMethodNameError,
    prefixedFieldName,
    protoPackageName,
    typeLikeName,
  )
import Turtle (FilePath, directory, filename)

-------------------------------------------------------------------------------

-- | Proto option to enable/disable batching in streams
batchedStreamOptionIdent :: DotProtoIdentifier
batchedStreamOptionIdent = Single "hs_grpc_mqtt_batched_stream"

forEachService ::
  Turtle.FilePath ->
  Batched ->
  (String -> [(String, Batched, ExpQ, Name)] -> ExceptT CompileError Q a) ->
  Q [a]
forEachService protoFilepath defBatchedStream action = showErrors . runExceptT $ do
  let protoFile = filename protoFilepath
      protoDir = directory protoFilepath

  dotproto <- importProto [protoDir] protoFile protoFile
  packageName <- dpIdentQualName =<< protoPackageName (protoPackage dotproto)

  let services = [(name, parts) | DotProtoService _ name parts <- protoDefinitions dotproto]

  forM services $ \(name, parts) -> do
    serviceName <- typeLikeName =<< dpIdentUnqualName name
    let endpointPrefix = "/" <> packageName <> "." <> serviceName <> "/"

    let isBatchedStreamEnabled :: [DotProtoOption] -> Maybe Batched
        isBatchedStreamEnabled opts =
          let maybeOpt = find (\opt -> dotProtoOptionIdentifier opt == batchedStreamOptionIdent) opts
              isBatched opt =
                if dotProtoOptionValue opt == BoolLit True
                  then Batched
                  else Unbatched
           in isBatched <$> maybeOpt

    let serviceUsesBatchedStream :: Maybe Batched
        serviceUsesBatchedStream = isBatchedStreamEnabled $ mapMaybe toOption parts
          where
            toOption (DotProtoServiceOption opt) = Just opt
            toOption _ = Nothing

    let methodUsesBatchedStream :: RPCMethod -> Maybe Batched
        methodUsesBatchedStream = isBatchedStreamEnabled . rpcMethodOptions

    let serviceMethodName (DotProtoServiceRPCMethod method@RPCMethod{..}) = do
          case rpcMethodName of
            Single nm -> do
              let useBatchedStream = fromMaybe defBatchedStream $ methodUsesBatchedStream method <|> serviceUsesBatchedStream

              let streamingWrapper =
                    case (rpcMethodRequestStreaming, rpcMethodResponseStreaming) of
                      (NonStreaming, Streaming) -> [e|wrapServerStreamingClientHandler useBatchedStream|]
                      (NonStreaming, NonStreaming) -> [e|wrapUnaryClientHandler|]
                      (Streaming, NonStreaming) -> [e|wrapClientStreamingClientHandler|]
                      (Streaming, Streaming) -> [e|wrapBiDiStreamingClientHandler useBatchedStream|]
              clientFun <- prefixedFieldName serviceName nm
              return [(endpointPrefix <> nm, useBatchedStream, streamingWrapper, mkName clientFun)]
            _ -> invalidMethodNameError rpcMethodName
        serviceMethodName _ = pure []

    serviceMethods <- foldMapM serviceMethodName parts
    action serviceName serviceMethods
  where
    showErrors = fmap (either (fail . show) id)
