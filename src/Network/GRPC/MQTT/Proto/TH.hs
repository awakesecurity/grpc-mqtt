
-- |
-- Module      :  Network.GRPC.MQTT.Proto.TH
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see LICENSE
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- Template haskell functions for creating splices from protocol buffers.
--
-- @since 1.0.0
module Network.GRPC.MQTT.Proto.TH
  ( -- * Quotation

    -- ** Lookup
    queryProtoTypeNameQ,

    -- ** Proto Names
    formatTypeNameQ,
    protoPackageIdQ,
    toProtoNameQ,
    toQualProtoNameQ,
    makeServiceFieldNameQ,

    -- ** Error Reporting
    throwCompileErrorQ,
    throwLocationQ,
  )
where

--------------------------------------------------------------------------------

import Language.Haskell.TH (Name, Q)
import Language.Haskell.TH qualified as TH

import Proto3.Suite.DotProto
  ( DotProtoIdentifier,
    DotProtoPackageSpec,
  )
import Proto3.Suite.DotProto qualified as DotProto
import Proto3.Suite.DotProto.Generate (CompileError)
import Proto3.Suite.DotProto.Internal qualified as DotProto
import Proto3.Suite.DotProto.Internal.Compat (prefixedMethodName)

import Relude

import Text.Show qualified as Show

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Proto (showCompileError, showProtoId)

-- Quotation - Lookup ----------------------------------------------------------

-- | Retrieves the haskell type 'Name' associated with the 'DotProtoIdentifier'.
-- Aborts the current splice's computation with a "not in scope" error if no
-- type constructor could be found.
--
-- @since 1.0.0
queryProtoTypeNameQ :: DotProtoIdentifier -> Q Name
queryProtoTypeNameQ typeId = do
  -- Apply type-casing (pascal case) to @typeId@ and perform namespace lookup.
  typeNm <- formatTypeNameQ =<< toProtoNameQ typeId
  hsName <- TH.lookupTypeName typeNm
  case hsName of
    Nothing -> throwTypeNotInScopeQ typeId
    Just nm -> pure nm

-- Quotation - Proto Names -----------------------------------------------------

-- | Applies type-case (or pascal case) formatting to the string.
--
-- @since 1.0.0
formatTypeNameQ :: String -> Q String
formatTypeNameQ nm = hoistCompileErrorQ (DotProto.typeLikeName nm)

-- | Obtain the name of a proto3 package from a 'DotProtoPacketSpec'.
--
-- @since 1.0.0
protoPackageIdQ :: DotProtoPackageSpec -> Q DotProtoIdentifier
protoPackageIdQ spec = hoistCompileErrorQ (DotProto.protoPackageName spec)

-- | Accesses the unqualified base name of the 'DotProtoIdentifier'.
--
-- @since 1.0.0
toProtoNameQ :: DotProtoIdentifier -> Q String
toProtoNameQ idt = hoistCompileErrorQ (DotProto.dpIdentUnqualName idt)

-- | Accesses the qualified name of the 'DotProtoIdentifier'.
--
-- @since 1.0.0
toQualProtoNameQ :: DotProtoIdentifier -> Q String
toQualProtoNameQ idt = hoistCompileErrorQ (DotProto.dpIdentQualName idt)

-- | Constructs a qualified RPC name from the 'DotProtoIdentifier' of the RPC
-- and the service the RPC belongs to.
--
-- @since 1.0.0
makeServiceFieldNameQ :: DotProtoIdentifier -> DotProtoIdentifier -> Q Name
makeServiceFieldNameQ svcId rpcId = do
  svcNm <- toProtoNameQ svcId
  rpcNm <- toProtoNameQ rpcId
  TH.mkName <$> hoistCompileErrorQ (prefixedMethodName svcNm rpcNm)

-- Quotation - Error Reporting -------------------------------------------------

-- | TODO
--
-- @since 1.0.0
throwTypeNotInScopeQ :: DotProtoIdentifier -> Q a
throwTypeNotInScopeQ idt =
  let idtS :: String
      idtS = "\"" ++ showProtoId idt ++ "\""
   in throwLocationQ ("not in scope: proto-haskell type with the name " ++ idtS)

-- | Fails 'Q' reporting the compile error with the location information for the
-- current splice context.
--
-- @since 1.0.0
throwCompileErrorQ :: CompileError -> Q a
throwCompileErrorQ err = throwLocationQ (showCompileError err)

-- | Fails 'Q' reporting the given error annotated with formatted location
-- information for the current splice context.
--
-- @since 1.0.0
throwLocationQ :: String -> Q a
throwLocationQ issue = do
  loc <- TH.location
  fail (Show.shows (TH.ppr loc) ": " ++ issue)

--------------------------------------------------------------------------------

hoistCompileErrorQ :: Either CompileError a -> Q a
hoistCompileErrorQ x = either throwCompileErrorQ pure x
