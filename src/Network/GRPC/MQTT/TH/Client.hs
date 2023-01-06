{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      :  Network.GRPC.MQTT.TH.Client
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- @since 1.0.0
module Network.GRPC.MQTT.TH.Client
  ( -- * TODO
    makeMQTTClientFuncs,

    -- * Quotation
    makeClientHandlerSigQ,
    makeClientHandlerExpQ,

    -- ** Names
    makeClientMethodNameQ,
    makeClientEndpointNameQ,
    makeClientHandlerNameQ,

    -- * Errors
    throwCompileErrorQ,
    throwLocationQ,

    -- * Re-exports
    Batched (Batched, Unbatched),
    MethodName (MethodName),
    mqttRequest,
  )
where

--------------------------------------------------------------------------------

import Language.Haskell.TH (Clause, Dec, Exp, FieldExp, Q, Type)
import Language.Haskell.TH qualified as TH

import Network.GRPC.HighLevel (MethodName)
import Network.GRPC.HighLevel qualified as GRPC

import Network.MQTT.Topic (Topic)

import Proto3.Suite.DotProto (DotProtoIdentifier, RPCMethod)
import Proto3.Suite.DotProto qualified as DotProto

import Relude hiding (Type)

import Turtle (FilePath)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Client (MQTTGRPCClient, mqttRequest)
import Network.GRPC.MQTT.Option.Batched (Batched (Batched, Unbatched))
import Network.GRPC.MQTT.Proto
  ( ProtoService (serviceName),
    methodsOf,
    servicesOf,
  )
import Network.GRPC.MQTT.Proto.TH
  ( formatTypeNameQ,
    makeServiceFieldNameQ,
    protoPackageIdQ,
    queryProtoTypeNameQ,
    throwCompileErrorQ,
    throwLocationQ,
    toProtoNameQ,
    toQualProtoNameQ,
  )
import Network.GRPC.MQTT.TH.Proto
  ( ProtoOptionMap,
    makeProtoOptionMapQ,
    openProtoFileQ,
    queryMethodOptionsQ,
  )
import Network.GRPC.MQTT.Types (MQTTRequest, MQTTResult)

-- Quotation -------------------------------------------------------------------

makeMQTTClientFuncs :: Turtle.FilePath -> Q [Dec]
makeMQTTClientFuncs filepath = do
  dotproto <- openProtoFileQ filepath
  fileopts <- makeProtoOptionMapQ dotproto

  pkgId <- protoPackageIdQ (DotProto.protoPackage dotproto)
  funDecs <- servicesOf dotproto \service -> do
    let svcId = serviceName service

    fields <- methodsOf service \rpc -> do
      field <- makeServiceFieldNameQ svcId (DotProto.rpcMethodName rpc)
      value <- makeClientHandlerExpQ pkgId svcId rpc fileopts
      pure (field, value)

    funSig <- makeClientHandlerSigQ svcId
    funExp <- makeServiceExp svcId fields
    makeHandler svcId funSig funExp

  pure (concat funDecs)
  where
    makeHandler :: DotProtoIdentifier -> Type -> Exp -> Q [Dec]
    makeHandler svcId funSig funExp = do
      name <- TH.mkName <$> makeClientHandlerNameQ svcId
      let funType = TH.SigD name funSig
          funImpl = TH.FunD name [makeHandlerBody funExp]
       in pure [funType, funImpl]

    makeHandlerBody :: Exp -> Clause
    makeHandlerBody expr = do
      let pats = map (TH.VarP . TH.mkName) ["client", "baseTopic"]
          body = TH.NormalB expr
       in TH.Clause pats body []

    makeServiceExp :: DotProtoIdentifier -> [FieldExp] -> Q Exp
    makeServiceExp svcId recFields = do
      svcNm <- toProtoNameQ svcId
      recNm <- formatTypeNameQ svcNm
      pure (TH.RecConE (TH.mkName recNm) recFields)

-- | Constructs gRPC handler function type signature. Fails if the string does
-- not refer to a type constructor that visible to the call site's namespace.
--
-- @
-- makeClientHandlerSigQ (DotProto.Single "HandlerType")
-- @
--
-- @since 1.0.0
makeClientHandlerSigQ :: DotProtoIdentifier -> Q Type
makeClientHandlerSigQ typeId = do
  typeNm <- queryProtoTypeNameQ typeId
  let tyCon :: Q Type
      tyCon = TH.conT typeNm
   in [t|MQTTGRPCClient -> Topic -> $tyCon MQTTRequest MQTTResult|]

-- | TODO
--
-- @since 1.0.0
makeClientHandlerExpQ ::
  DotProtoIdentifier ->
  DotProtoIdentifier ->
  RPCMethod ->
  ProtoOptionMap ->
  Q Exp
makeClientHandlerExpQ pkgId svcId rpc optmap = do
  name <- makeClientMethodNameQ pkgId svcId (DotProto.rpcMethodName rpc)
  opts <- queryMethodOptionsQ rpc optmap
  let var0 = TH.varE (TH.mkName "client")
      var1 = TH.varE (TH.mkName "baseTopic")
   in [e|mqttRequest $var0 $var1 (GRPC.MethodName name) opts|]

-- Quotation - Names -----------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
makeClientMethodNameQ ::
  DotProtoIdentifier ->
  DotProtoIdentifier ->
  DotProtoIdentifier ->
  Q String
makeClientMethodNameQ pkgId svcId rpcId = do
  svcNm <- makeClientEndpointNameQ pkgId svcId
  rpcNm <- toQualProtoNameQ rpcId
  pure ("/" ++ svcNm ++ "/" ++ rpcNm)

-- | @'makeClientEndpointNameQ' pkg svc@ produces a client endpoint name from
-- a package identifier @pkg@ and a service identifier @svc@.
--
-- * Type-case formatting (or pascal case) is applied to the service identifier.
--
-- * The service identifier @svc@ should refer to a service defined in the
--   package @pkg@, but this is not checked.
--
-- >>> let pkg = DotProto.Dots (DotProto.Path (fromList ["cool", "proto", "package"]))
-- >>> let svc = DotProto.Single "ServiceName"
-- >>> $(makeClientEndpointNameQ pkg svc >>= TH.stringE)
-- "cool.proto.package.ServiceName"
--
-- @since 1.0.0
makeClientEndpointNameQ :: DotProtoIdentifier -> DotProtoIdentifier -> Q String
makeClientEndpointNameQ pkgId svcId = do
  pkgNm <- toQualProtoNameQ pkgId
  svcNm <- formatTypeNameQ =<< toProtoNameQ svcId
  pure (pkgNm ++ "." ++ svcNm)

-- | @'makeClientEndpointNameQ' idt@ produces a name of a client handler
-- function with the (unqualified) 'DotProtoIdentifier' @idt@.
--
-- >>> let idt = DotProto.Dots (DotProto.Path (fromList ["qualified", "ServiceName"]))
-- >>> $(makeClientHandlerNameQ idt >>= TH.stringE)
-- "serviceNameMqttClient"
--
-- @since 1.0.0
makeClientHandlerNameQ :: DotProtoIdentifier -> Q String
makeClientHandlerNameQ svcId = do
  svcNm <- toProtoNameQ svcId
  pure (DotProto.fieldLikeName svcNm ++ "MqttClient")
