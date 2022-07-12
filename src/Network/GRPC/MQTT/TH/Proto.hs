-- Copyright (c) 2021-2022 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- | TODO
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.TH.Proto
  ( -- * Template Haskell
    openProtoFileQ,
    makeProtoOptionMapQ,
    queryMethodOptionsQ,

    -- * ProtoOptionMap
    ProtoOptionMap,
    emptyProtoOptionMap,
    lookupProtoOptionMap,
    insertProtoOptionMap,

    -- * OptionReader
    OptionReader,
    makeProtoOptionConfig,

    -- ** Context
    OptionReaderCtx (OptionReaderCtx, ctxOptionDefs, ctxSetOptions),

    -- ** Reading
    readFileProtoOptions,
    readServiceProtoOptions,
    readMethodProtoOptions,

    -- ** Query
    queryOptionConfig,
    queryOptionConfigM,

    -- * TODO
    forEachService,
  )
where

--------------------------------------------------------------------------------

import Control.Monad.Except (Except, MonadError, runExcept, throwError)

import Data.Map.Strict qualified as Map

import Language.Haskell.TH (ExpQ, Name, Q)
import Language.Haskell.TH qualified as TH
import Language.Haskell.TH.Syntax qualified as TH

import Proto3.Suite.DotProto qualified as DotProto
import Proto3.Suite.DotProto.AST
  ( DotProto,
    DotProtoIdentifier,
    DotProtoOption (dotProtoOptionIdentifier),
    DotProtoPackageSpec,
    DotProtoServicePart (DotProtoServiceOption, DotProtoServiceRPCMethod),
    DotProtoValue (BoolLit),
    Path,
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
import Proto3.Suite.DotProto.Internal (CompileError, invalidMethodNameError)
import Proto3.Suite.DotProto.Internal qualified as DotProto

import Relude

import Turtle qualified

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Option
  ( ProtoOptions
      ( ProtoOptions,
        rpcBatchStream,
        rpcClientCLevel,
        rpcServerCLevel
      ),
    defaultProtoOptions,
  )
import Network.GRPC.MQTT.Option.Batched (Batched (Batched, Unbatched))
import Network.GRPC.MQTT.Proto
  ( ProtoDatum,
    ProtoOptionError (OptionValueTypeMismatch),
    ProtoOptionSet,
    ProtoService (ProtoService),
    castDatum,
    datumRepOf,
    getFileOptions,
    getFileServices,
    getMethodOptions,
    getServiceOptions,
    lookupOption,
    methodsOf,
    openProtoFileIO,
    servicesOf,
    throwCompileErrorIO,
  )
import Network.GRPC.MQTT.Wrapping
  ( wrapBiDiStreamingClientHandler,
    wrapClientStreamingClientHandler,
    wrapServerStreamingClientHandler,
    wrapUnaryClientHandler,
  )

import Proto3.Suite.DotProto.Internal.Compat (prefixedMethodName)

--------------------------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
openProtoFileQ :: Turtle.FilePath -> Q DotProto
openProtoFileQ filepath = do
  dotproto <- liftIO (openProtoFileIO filepath)
  TH.addDependentFile (Turtle.encodeString filepath)
  pure dotproto

-- | TODO
--
-- @since 0.1.0.0
makeProtoOptionMapQ :: DotProto -> Q ProtoOptionMap
makeProtoOptionMapQ dotproto =
  case makeProtoOptionConfig dotproto of
    Left err -> fail (displayException err)
    Right os -> pure os

-- | TODO
--
-- @since 0.1.0.0
queryMethodOptionsQ :: RPCMethod -> ProtoOptionMap -> Q ProtoOptions
queryMethodOptionsQ rpc optmap =
  case lookupProtoOptionMap rpc optmap of
    Nothing -> fail ("internal error: missing options the RPC " ++ show rpc)
    Just os -> pure os

--------------------------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
newtype ProtoOptionMap = ProtoOptionMap
  {getProtoOptionConfig :: Map RPCMethod ProtoOptions}
  deriving (Eq, Ord, Show)

-- | TODO
--
-- @since 0.1.0.0
emptyProtoOptionMap :: ProtoOptionMap
emptyProtoOptionMap = ProtoOptionMap Map.empty

-- | TODO
--
-- @since 0.1.0.0
lookupProtoOptionMap :: RPCMethod -> ProtoOptionMap -> Maybe ProtoOptions
lookupProtoOptionMap key (ProtoOptionMap kvs) = Map.lookup key kvs

-- | TODO
--
-- @since 0.1.0.0
insertProtoOptionMap :: RPCMethod -> ProtoOptions -> ProtoOptionMap -> ProtoOptionMap
insertProtoOptionMap key val (ProtoOptionMap kvs) = ProtoOptionMap (Map.insert key val kvs)

-- OptionReader ----------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
newtype OptionReader a = OptionReader
  { unOptionReader ::
      ReaderT OptionReaderCtx (StateT ProtoOptionMap (Except ProtoOptionError)) a
  }
  deriving newtype (Functor, Applicative, Monad)
  deriving newtype
    ( MonadError ProtoOptionError
    , MonadReader OptionReaderCtx
    , MonadState ProtoOptionMap
    )

-- | TODO
--
-- @since 0.1.0.0
data OptionReaderCtx = OptionReaderCtx
  { ctxOptionDefs :: ProtoOptions
  , ctxSetOptions :: ProtoOptionSet
  }

-- | TODO
--
-- @since 0.1.0.0
makeProtoOptionConfig :: DotProto -> Either ProtoOptionError ProtoOptionMap
makeProtoOptionConfig dotproto = do
  opts <- getFileOptions dotproto
  let ctx :: OptionReaderCtx
      ctx = OptionReaderCtx defaultProtoOptions opts
   in unOptionReader makeFileConfig
        & flip runReaderT ctx
        & flip execStateT emptyProtoOptionMap
        & runExcept
  where
    setLocalDefaults :: ProtoOptions -> OptionReader a -> OptionReader a
    setLocalDefaults opts = local \ctx -> ctx{ctxOptionDefs = opts}

    setLocalOptions :: ProtoOptionSet -> OptionReader a -> OptionReader a
    setLocalOptions opts = local \ctx -> ctx{ctxSetOptions = opts}

    -- Traverses the toplevel 'DotProto' @dotproto@ to populate the
    -- 'OptionConfig' state.
    makeFileConfig :: OptionReader ()
    makeFileConfig = do
      -- Within a 'DotProto' (the top level syntax for protobuf files), a new
      -- 'ProtoOptions' is constructed from the file-level protobuf options .
      --
      -- Set @defs@ to use as the default 'ProtoOptions' value for all services
      -- defined in @dotproto@.
      defs <- readFileProtoOptions
      setLocalDefaults defs do
        () <$ servicesOf dotproto \service -> do
          optset <- getServiceOptions service
          setLocalOptions optset (makeServiceConfig service)

    -- Traverses each service defined in the file @dotproto@ to populate the
    -- 'OptionConfig' state.
    makeServiceConfig :: ProtoService -> OptionReader ()
    makeServiceConfig service = do
      -- Set @defs@ to be the default 'ProtoOptions' value for all RPC methods
      -- that are defined within the scope of @service@.
      defs <- readServiceProtoOptions
      setLocalDefaults defs do
        () <$ methodsOf service \rpc -> do
          optset <- getMethodOptions rpc
          setLocalOptions optset (makeMethodConfig rpc)

    -- Sets the 'ProtoOptions' configuration for a single RPC method.
    makeMethodConfig :: RPCMethod -> OptionReader ()
    makeMethodConfig rpc = do
      -- Record @opts@ in the options configuration whenever the 'ProtoOptions'
      -- set for @method@ differ from the default options set for @dotproto@.
      opts <- readMethodProtoOptions
      modify (insertProtoOptionMap rpc opts)

-- OptionReader - Reading ------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
readFileProtoOptions :: OptionReader ProtoOptions
readFileProtoOptions = do
  defs <- asks ctxOptionDefs
  ProtoOptions
    <$> queryOptionConfig "batched_stream_file" (rpcBatchStream defs)
    <*> queryOptionConfigM "server_clevel_file" (rpcServerCLevel defs)
    <*> queryOptionConfigM "client_clevel_file" (rpcClientCLevel defs)

-- | TODO
--
-- @since 0.1.0.0
readServiceProtoOptions :: OptionReader ProtoOptions
readServiceProtoOptions = do
  defs <- asks ctxOptionDefs
  ProtoOptions
    <$> queryOptionConfig "batched_stream_service" (rpcBatchStream defs)
    <*> queryOptionConfigM "server_clevel_service" (rpcServerCLevel defs)
    <*> queryOptionConfigM "client_clevel_service" (rpcClientCLevel defs)

-- | TODO
--
-- @since 0.1.0.0
readMethodProtoOptions :: OptionReader ProtoOptions
readMethodProtoOptions = do
  defs <- asks ctxOptionDefs
  ProtoOptions
    <$> queryOptionConfig "batched_stream" (rpcBatchStream defs)
    <*> queryOptionConfigM "server_clevel" (rpcServerCLevel defs)
    <*> queryOptionConfigM "client_clevel" (rpcClientCLevel defs)

-- OptionReader - Query --------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
queryOptionConfig :: ProtoDatum a => String -> a -> OptionReader a
queryOptionConfig nm def = do
  opts <- asks ctxSetOptions
  let idt :: DotProtoIdentifier
      idt = makeQualifiedId nm
   in case lookupOption idt opts of
        Nothing -> pure def
        Just val -> castProtoOption (DotProto.DotProtoOption idt val)

-- | TODO
--
-- @since 0.1.0.0
queryOptionConfigM ::
  ProtoDatum a =>
  String ->
  Maybe a ->
  OptionReader (Maybe a)
queryOptionConfigM nm def = do
  opts <- asks ctxSetOptions
  let idt :: DotProtoIdentifier
      idt = makeQualifiedId nm
   in case lookupOption idt opts of
        Nothing -> pure def
        Just val -> do
          val' <- castProtoOption (DotProto.DotProtoOption idt val)
          pure (Just val')

-- | TODO
--
-- @since 0.1.0.0
castProtoOption :: forall a. ProtoDatum a => DotProtoOption -> OptionReader a
castProtoOption opt =
  let val :: DotProtoValue
      val = DotProto.dotProtoOptionValue opt
   in case castDatum val of
        Just px -> pure px
        Nothing ->
          let issue :: ProtoOptionError
              issue = OptionValueTypeMismatch (datumRepOf val) opt
           in throwError issue

makeQualifiedId :: String -> DotProtoIdentifier
makeQualifiedId nm =
  let path :: Path
      path = DotProto.Path ("haskell" :| ["grpc", "mqtt", nm])
   in DotProto.Dots path

--------------------------------------------------------------------------------

-- | Proto option to enable/disable batching in streams
batchedStreamOptionIdent :: DotProtoIdentifier
batchedStreamOptionIdent = DotProto.Single "hs_grpc_mqtt_batched_stream"

forEachService ::
  Turtle.FilePath ->
  Batched ->
  (String -> [(String, Batched, ExpQ, Name)] -> ExceptT CompileError Q a) ->
  Q [a]
forEachService filepath defBatchedStream action = do
  dotproto <- openProtoFileQ filepath

  pkgName <- toPackageNameQ (DotProto.protoPackage dotproto)
  pkgQual <- toQualifiedNameQ pkgName

  forM (getFileServices dotproto) \(ProtoService nm ps) -> do
    serviceName <- toUnqualifiedNameQ nm
    let endpointPrefix = "/" ++ pkgQual ++ "." ++ serviceName ++ "/"

    let isBatchedStreamEnabled :: [DotProtoOption] -> Maybe Batched
        isBatchedStreamEnabled opts =
          let maybeOpt = find (\opt -> dotProtoOptionIdentifier opt == batchedStreamOptionIdent) opts
              isBatched opt =
                if dotProtoOptionValue opt == BoolLit True
                  then Batched
                  else Unbatched
           in isBatched <$> maybeOpt

    let serviceUsesBatchedStream :: Maybe Batched
        serviceUsesBatchedStream = isBatchedStreamEnabled $ mapMaybe toOption ps
          where
            toOption (DotProtoServiceOption opt) = Just opt
            toOption _ = Nothing

    let methodUsesBatchedStream :: RPCMethod -> Maybe Batched
        methodUsesBatchedStream = isBatchedStreamEnabled . rpcMethodOptions

    let serviceMethodName (DotProtoServiceRPCMethod method@RPCMethod{..}) = do
          case rpcMethodName of
            DotProto.Single rpcNm -> do
              let useBatchedStream = fromMaybe defBatchedStream $ methodUsesBatchedStream method <|> serviceUsesBatchedStream

              let streamingWrapper =
                    case (rpcMethodRequestStreaming, rpcMethodResponseStreaming) of
                      (NonStreaming, Streaming) -> [e|wrapServerStreamingClientHandler useBatchedStream|]
                      (NonStreaming, NonStreaming) -> [e|wrapUnaryClientHandler|]
                      (Streaming, NonStreaming) -> [e|wrapClientStreamingClientHandler|]
                      (Streaming, Streaming) -> [e|wrapBiDiStreamingClientHandler useBatchedStream|]
              clientFun <- mapCompileErrorQ (prefixedMethodName serviceName rpcNm)
              return [(endpointPrefix <> rpcNm, useBatchedStream, streamingWrapper, TH.mkName clientFun)]
            _ -> mapCompileErrorQ (invalidMethodNameError rpcMethodName)
        serviceMethodName _ = pure []

    serviceMethods <- foldMapM serviceMethodName ps
    result <- runExceptT (action serviceName serviceMethods)
    mapCompileErrorQ result
  where
    toPackageNameQ :: DotProtoPackageSpec -> Q DotProtoIdentifier
    toPackageNameQ pkg = mapCompileErrorQ (DotProto.protoPackageName pkg)

    toUnqualifiedNameQ :: DotProtoIdentifier -> Q String
    toUnqualifiedNameQ idt = mapCompileErrorQ do
      nm <- DotProto.dpIdentUnqualName idt
      DotProto.typeLikeName nm

    toQualifiedNameQ :: DotProtoIdentifier -> Q String
    toQualifiedNameQ idt = mapCompileErrorQ (DotProto.dpIdentQualName idt)

    mapCompileErrorQ :: Either CompileError a -> Q a
    mapCompileErrorQ (Left err) = liftIO (throwCompileErrorIO filepath err)
    mapCompileErrorQ (Right x) = pure x
