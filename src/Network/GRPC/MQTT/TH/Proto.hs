{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.GRPC.MQTT.TH.Proto where

import Relude hiding (FilePath, foldMapM)

import Network.GRPC.MQTT.Wrapping (wrapServerStreamingClientHandler, wrapUnaryClientHandler)

import Filesystem.Path (FilePath, directory, filename)
import Language.Haskell.TH
import Proto3.Suite.DotProto.AST
import Proto3.Suite.DotProto.Internal

forEachService :: FilePath -> (String -> [(String, Name, Name)] -> ExceptT CompileError Q a) -> Q [a]
forEachService protoFilepath action =
  either (fail . show) pure =<< runExceptT (do
    let protoFile = filename protoFilepath
        protoDir = directory protoFilepath

    dotproto <- importProto [protoDir] protoFile protoFile

    let isService :: DotProtoDefinition -> Bool
        isService DotProtoService{} = True
        isService _ = False

    let services = filter isService (protoDefinitions dotproto)

    forM services $ \(DotProtoService _ name parts) -> do
      serviceName <- typeLikeName =<< dpIdentUnqualName name
      packageName <- dpIdentQualName =<< protoPackageName (protoPackage dotproto)
      let endpointPrefix = "/" <> packageName <> "." <> serviceName <> "/"

      let serviceMethodName (DotProtoServiceRPCMethod RPCMethod{..}) = do
            case rpcMethodName of
              Single nm -> do
                streamingWrapper <-
                  case (rpcMethodRequestStreaming, rpcMethodResponseStreaming) of
                    (NonStreaming, Streaming) -> pure 'wrapServerStreamingClientHandler
                    (NonStreaming, NonStreaming) -> pure 'wrapUnaryClientHandler
                    _ -> _unimplementedError "Client streaming not supported"
                clientFun <- prefixedFieldName serviceName nm
                return [(endpointPrefix <> nm, streamingWrapper, mkName clientFun)]
              _ -> invalidMethodNameError rpcMethodName
          serviceMethodName _ = pure []

      serviceMethods <- foldMapM serviceMethodName parts
      action serviceName serviceMethods
  )
