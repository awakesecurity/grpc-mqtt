{-# LANGUAGE AllowAmbiguousTypes #-}

-- | TODO
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Proto
  ( -- * Data
    castDatumRep,

    -- ** Representation
    DatumRep
      ( DRepBoolean,
        DRepDecimal,
        DRepInteger,
        DRepString,
        DRepIdent
      ),

    -- ** ProtoDatum
    ProtoDatum,
    datumRep,
    castDatum,

    -- * Proto Names
    toProtoNameList,

    -- * Proto Options
    ProtoOptionSet (ProtoOptionSet, getProtoOptionSet),
    insertOption,
    lookupOption,

    -- * Proto Files
    getFileServices,
    getFileOptions,

    -- * Proto Services
    ProtoService (ProtoService, serviceName, serviceDefs),
    getServiceOptions,

    -- * Proto Methods
    getMethodOptions,
  )
where

---------------------------------------------------------------------------------

import Data.Data (cast, eqT, gmapQ)
import Data.Type.Equality ((:~:) (Refl))

import Data.List.NonEmpty qualified as NonEmpty
import Data.Map qualified as Map

import Network.GRPC.HighLevel.Generated
  ( GRPCMethodType (Normal, ClientStreaming, ServerStreaming, BiDiStreaming)
  )

import Proto3.Suite.DotProto
  ( DotProto,
    DotProtoDefinition,
    DotProtoIdentifier,
    RPCMethod,
    DotProtoOption,
    DotProtoServicePart,
    DotProtoValue,
  )
import Proto3.Suite.DotProto qualified as DotProto

import Relude

---------------------------------------------------------------------------------

-- Orphan instance @'Data' 'DotProtoValue'@
import Proto3.Suite.Orphans ()

-- Data -------------------------------------------------------------------------

-- | Type-safe cast operation from a 'DotProtoValue' to the equivalent Haskell
-- representation.
--
-- >>> castDatumRep @Bool DRepBoolean (DotProto.BoolLit False)
-- Just False
--
-- The cast will fail returning 'Nothing' if the given 'DatumRep' does not match
-- the representation of the 'DotProtoValue' and the expected result type @a@.
--
-- >>> -- Fails because a 'DRepBoolean' scalar cannot be cast to a 'String'.
-- >>> castDatumRep @String DRepString (DotProto.BoolLit True)
-- Nothing
--
-- @since 0.1.0.0
castDatumRep :: forall a. Typeable a => DatumRep -> DotProtoValue -> Maybe a
castDatumRep datrep val =
  case datrep of
    DRepBoolean -> do
      Refl <- eqT @Bool @a
      castValue val
    DRepDecimal -> do
      Refl <- eqT @Double @a
      castValue val
    DRepInteger -> do
      Refl <- eqT @Int @a
      castValue val
    DRepString -> do
      Refl <- eqT @String @a
      castValue val
    DRepIdent -> do
      Refl <- eqT @DotProtoIdentifier @a
      castValue val
  where
    castValue :: DotProtoValue -> Maybe a
    castValue x = do
      casted <- sequence (gmapQ cast x)
      viaNonEmpty head casted

-- Protobuf Data - Representation -----------------------------------------------

-- | 'DatumRep' enumerates the /kinds/ of scalars that can be represented by a
-- 'DotProtoValue' value.
--
-- @since 0.1.0.0
data DatumRep
  = -- | Boolean representations correspond to the @bool@ .proto type.
    DRepBoolean
  | -- | Decimal representations capture the @double@ and @float@ .proto types.
    DRepDecimal
  | -- | Integer representations capture all signed, unsigned, and fixed-width
    -- integer .proto types.
    DRepInteger
  | -- | String representations capture the @string@ and @bytes@ .proto types.
    DRepString
  | -- | An identifier representation corresponds to the name of an .proto
    -- enum value or a .proto message value.
    DRepIdent
  deriving (Enum, Eq, Ord, Show)

-- Data - ProtoDatum ------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
class ProtoDatum a where
  -- | TODO
  --
  -- @since 0.1.0.0
  datumRep :: DatumRep

  -- | TODO
  --
  -- @since 0.1.0.0
  castDatum :: DotProtoValue -> Maybe a
  castDatum val = castDatumRep (datumRep @a) val
  {-# INLINE castDatum #-}
  default castDatum :: Typeable a => DotProtoValue -> Maybe a

  {-# MINIMAL datumRep #-}

-- | @since 0.1.0.0
instance ProtoDatum Bool where
  datumRep = DRepBoolean

-- | @since 0.1.0.0
instance ProtoDatum Double where
  datumRep = DRepDecimal

-- | @since 0.1.0.0
instance ProtoDatum Float where
  datumRep = DRepDecimal

  castDatum x = fmap realToFrac (castDatum @Double x)

-- | @since 0.1.0.0
instance ProtoDatum Int where
  datumRep = DRepInteger

-- | @since 0.1.0.0
instance ProtoDatum String where
  datumRep = DRepString

-- | @since 0.1.0.0
instance ProtoDatum ByteString where
  datumRep = DRepString

  castDatum x = fmap fromString (castDatum x)

-- | @since 0.1.0.0
instance ProtoDatum DotProtoIdentifier where
  datumRep = DRepIdent

-- Proto Names ------------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
toProtoNameList :: DotProtoIdentifier -> [String]
toProtoNameList idt = case idt of
  DotProto.Anonymous -> []
  DotProto.Single nm -> [nm]
  DotProto.Dots idts ->
    let nms :: NonEmpty String
        nms = DotProto.components idts
     in NonEmpty.toList nms
  DotProto.Qualified idts0 idts1 -> do
    let nms0 = toProtoNameList idts0
        nms1 = toProtoNameList idts1
     in nms0 ++ nms1

-- Proto Options ----------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
newtype ProtoOptionSet = ProtoOptionSet
  {getProtoOptionSet :: Map DotProtoIdentifier DotProtoValue}
  deriving
    (Semigroup, Monoid)
    via Map DotProtoIdentifier DotProtoValue

-- | TODO
--
-- @since 0.1.0.0
insertOption :: DotProtoOption -> ProtoOptionSet -> ProtoOptionSet
insertOption opt (ProtoOptionSet kvs) =
  let key = DotProto.dotProtoOptionIdentifier opt
      val = DotProto.dotProtoOptionValue opt
   in ProtoOptionSet (Map.insert key val kvs)

-- | TODO
--
-- @since 0.1.0.0
lookupOption :: DotProtoIdentifier -> ProtoOptionSet -> Maybe DotProtoValue
lookupOption key (ProtoOptionSet kvs) = Map.lookup key kvs

-- Proto Files ------------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
getFileServices :: DotProto -> [ProtoService]
getFileServices dotproto =
  foldMap toService (DotProto.protoDefinitions dotproto)
  where
    toService :: DotProtoDefinition -> [ProtoService]
    toService (DotProto.DotProtoService _ idt ps) = [ProtoService idt ps]
    toService _ = []

-- | TODO
--
-- @since 0.1.0.0
getFileOptions :: DotProto -> ProtoOptionSet
getFileOptions dotproto =
  let opts :: [DotProtoOption]
      opts = DotProto.protoOptions dotproto
   in foldr insertOption mempty opts

-- Proto Services ---------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
data ProtoService = ProtoService
  { serviceName :: DotProtoIdentifier
  , serviceDefs :: [DotProtoServicePart]
  }

-- | TODO
--
-- @since 0.1.0.0
getServiceMethods :: ProtoService -> [RPCMethod]
getServiceMethods (ProtoService _ ps) = foldr toRPCs mempty ps
  where
    toRPCs :: DotProtoServicePart -> [RPCMethod] -> [RPCMethod]
    toRPCs (DotProto.DotProtoServiceRPCMethod rpc) rpcs = rpc : rpcs
    toRPCs _ rpcs = rpcs

-- | TODO
--
-- @since 0.1.0.0
getServiceOptions :: ProtoService -> ProtoOptionSet
getServiceOptions (ProtoService _ ps) = foldr toOptions mempty ps
  where
    toOptions :: DotProtoServicePart -> ProtoOptionSet -> ProtoOptionSet
    toOptions (DotProto.DotProtoServiceOption opt) opts = insertOption opt opts
    toOptions _ opts = opts

-- Proto Methods ---------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
getMethodType :: RPCMethod -> GRPCMethodType
getMethodType rpc =
  case DotProto.rpcMethodRequestStreaming rpc of
    DotProto.NonStreaming ->
      case DotProto.rpcMethodResponseStreaming rpc of
        DotProto.NonStreaming -> Normal
        DotProto.Streaming -> ServerStreaming
    DotProto.Streaming ->
      case DotProto.rpcMethodResponseStreaming rpc of
        DotProto.NonStreaming -> ClientStreaming
        DotProto.Streaming -> BiDiStreaming

-- | TODO
--
-- @since 0.1.0.0
getMethodOptions :: RPCMethod -> ProtoOptionSet
getMethodOptions rpc = foldr insertOption mempty (DotProto.rpcMethodOptions rpc)
