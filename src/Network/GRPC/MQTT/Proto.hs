{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TemplateHaskellQuotes #-}

-- | This module defines functions used by @grpc-mqtt@ internals for:
--
-- * Handling IO for protocol buffers.
--
-- * Manipulating the protobuf syntax trees.
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Proto
  ( -- * Proto IO
    openProtoFileIO,

    -- * Proto IO Errors
    ProtoIOError (ProtoIOError, ioeFilePath, ioeErrorTag),
    throwProtoInvalidExtensionIO,
    throwProtoDoesNotExistIO,
    throwProtoPathIsDirectoryIO,
    throwCompileErrorIO,

    -- ** Error Tags
    ProtoIOErrorTag
      ( ProtoInvalidExtension,
        ProtoFileDoesNotExist,
        ProtoPathIsDirectory
      ),

    -- * Proto Data Casts
    datumRepOf,
    castDatumRepWith,

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
    showProtoId,

    -- * ProtoOptionSet
    ProtoOptionSet (ProtoOptionSet, getProtoOptionSet),
    insertOption,
    insertOption',
    lookupOption,
    memberOption,

    -- ** Option Errors
    ProtoOptionError
      ( ProtoOptionAlreadySet,
        OptionValueTypeMismatch
      ),

    -- * Proto Files
    servicesOf,
    getFileServices,
    getFileOptions,

    -- * Proto Services
    ProtoService (ProtoService, serviceName, serviceDefs),
    methodsOf,
    getServiceMethods,
    getServiceOptions,

    -- * Proto Methods
    getMethodOptions,

    -- * Proto Errors
    showCompileError,
  )
where

--------------------------------------------------------------------------------

import Control.Exception (ErrorCall (ErrorCallWithLocation), throwIO)

import Control.Monad.Except (MonadError, throwError)

import Data.Data (Data, cast, eqT, gmapQ)
import Data.Foldable (foldrM)
import Data.Traversable (for)
import Data.Type.Equality ((:~:) (Refl))

import Data.List.NonEmpty qualified as NonEmpty
import Data.Map qualified as Map

import Language.Haskell.TH (Name)

import Network.GRPC.HighLevel.Generated
  ( GRPCMethodType (BiDiStreaming, ClientStreaming, Normal, ServerStreaming),
  )

import Proto3.Suite.DotProto
  ( DotProto,
    DotProtoDefinition,
    DotProtoIdentifier,
    DotProtoOption,
    DotProtoServicePart,
    DotProtoValue,
    RPCMethod,
  )
import Proto3.Suite.DotProto qualified as DotProto
import Proto3.Suite.DotProto.Internal (CompileError)
import Proto3.Suite.DotProto.Internal qualified as DotProto

import Proto3.Wire.Decode (ParseError)
import Proto3.Wire.Decode qualified as Wire

import Relude

import Text.Show qualified as Show

import Turtle qualified

--------------------------------------------------------------------------------

-- Orphan instance @'Data' 'DotProtoValue'@
import Proto3.Suite.Orphans ()

-- Proto IO --------------------------------------------------------------------

-- | Read the contents of a *.proto file into a 'DotProto' syntax tree.
--
-- Raises 'ProtoIOError' 'IO' exceptions if the 'Turtle.FilePath' does not refer
-- to a valid *.proto file that can be read.
--
-- @since 0.1.0.0
openProtoFileIO :: Turtle.FilePath -> IO DotProto
openProtoFileIO filepath = do
  -- Test that the path @filepath@ exists.
  unlessM (Turtle.testpath filepath) do
    throwProtoDoesNotExistIO filepath

  -- Test that @filepath@ points to a file, not a directory.
  unlessM (Turtle.testfile filepath) do
    throwProtoPathIsDirectoryIO filepath

  -- Test that path @filepath@ has a *.proto extension.
  let isproto = Turtle.hasExtension filepath "proto"
  unless isproto (throwProtoInvalidExtensionIO filepath)

  -- Read the contents @filepath@, handle any protobuf compile errors should any
  -- be raised by @importProtoFile@.
  let file = Turtle.filename filepath
  let dire = Turtle.directory filepath
  runExceptT (DotProto.importProto [dire] file file) >>= \case
    Left err -> throwCompileErrorIO filepath err
    Right dp -> pure dp

-- Proto IO Errors -------------------------------------------------------------

-- | 'ProtoIOError' represents an IO error that occurs when reading or parsing
-- the contents of a *.proto file.
--
-- @since 0.1.0.0
data ProtoIOError = ProtoIOError
  { ioeFilePath :: Turtle.FilePath
  , ioeErrorTag :: ProtoIOErrorTag
  }
  deriving stock (Eq, Ord)

-- | @since 0.1.0.0
instance Show ProtoIOError where
  show (ProtoIOError filepath tag) =
    let locS = "(" ++ Turtle.encodeString filepath ++ "): "
        tagS = Show.shows tag "."
     in "protobuf IO error" ++ locS ++ tagS
  {-# INLINE show #-}

-- | @since 0.1.0.0
instance Exception ProtoIOError where
  displayException ioe = show ioe
  {-# INLINE displayException #-}

-- | Throws a 'ProtoIOError' IO exception with the 'InvalidProtoExtension' tag
-- for the given filepath.
--
-- @since 0.1.0.0
throwProtoInvalidExtensionIO :: Turtle.FilePath -> IO a
throwProtoInvalidExtensionIO = throwProtoIO ProtoInvalidExtension

-- | Throws a 'ProtoIOError' IO exception with the 'ProtoFileDoesNotExist' tag
-- for the given filepath.
--
-- @since 0.1.0.0
throwProtoDoesNotExistIO :: Turtle.FilePath -> IO a
throwProtoDoesNotExistIO = throwProtoIO ProtoFileDoesNotExist

-- | Throws a 'ProtoIOError' IO exception with the 'ProtoPathIsDirectory' tag
-- for the given filepath.
--
-- @since 0.1.0.0
throwProtoPathIsDirectoryIO :: Turtle.FilePath -> IO a
throwProtoPathIsDirectoryIO = throwProtoIO ProtoPathIsDirectory

-- | Throws a 'CompileError' as an 'ErrorCall' IO exception using the filepath
--  as the 'ErrorCall' location.
--
-- @since 0.1.0.0
throwCompileErrorIO :: Turtle.FilePath -> CompileError -> IO a
throwCompileErrorIO filepath err =
  let issue :: ErrorCall
      issue = ErrorCallWithLocation (Turtle.encodeString filepath) (showCompileError err)
   in throwIO issue

throwProtoIO :: ProtoIOErrorTag -> Turtle.FilePath -> IO a
throwProtoIO tag filepath = throwIO (ProtoIOError filepath tag)

-- Proto IO Errors - Error Tags ------------------------------------------------

-- | An enumeration of error codes that 'ProtoIOError' is tagged with.
--
-- @since 0.1.0.0
data ProtoIOErrorTag
  = ProtoInvalidExtension
  | ProtoFileDoesNotExist
  | ProtoPathIsDirectory
  deriving stock (Enum, Eq, Ord, Show)

-- | @since 0.1.0.0
instance Exception ProtoIOErrorTag where
  displayException ProtoInvalidExtension = "filepath must have a *.proto extension"
  displayException ProtoFileDoesNotExist = "proto filepath not found (does not exist)"
  displayException ProtoPathIsDirectory = "filepath refers to a directory (expected a file)"
  {-# INLINE displayException #-}

-- Proto Data Casts ------------------------------------------------------------

-- | Obtain the kind of 'DatumRep' used to represent a 'DotProtoValue'.
--
-- @since 0.1.0.0
datumRepOf :: DotProtoValue -> DatumRep
datumRepOf DotProto.BoolLit{} = DRepBoolean
datumRepOf DotProto.FloatLit{} = DRepDecimal
datumRepOf DotProto.Identifier{} = DRepIdent
datumRepOf DotProto.IntLit{} = DRepInteger
datumRepOf DotProto.StringLit{} = DRepString

-- | Type-safe cast operation from a 'DotProtoValue' to the equivalent Haskell
-- representation.
--
-- >>> castDatumRepWith @Bool DRepBoolean (DotProto.BoolLit False)
-- Just False
--
-- The cast will fail returning 'Nothing' if the given 'DatumRep' does not match
-- the representation of the 'DotProtoValue' and the expected result type @a@.
--
-- >>> -- Fails because a 'DRepBoolean' scalar cannot be cast to a 'String'.
-- >>> castDatumRepWith @String DRepString (DotProto.BoolLit True)
-- Nothing
--
-- @since 0.1.0.0
castDatumRepWith :: forall a. Typeable a => DatumRep -> DotProtoValue -> Maybe a
castDatumRepWith datrep val =
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

-- Protobuf Data - Representation ----------------------------------------------

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
  deriving stock (Data, Enum, Eq, Ord, Show)

-- Data - ProtoDatum ------------------------------------------------------------

-- | 'ProtoDatum' is the class of types that can be obtained from a
-- 'DotProtoValue' literal.
--
-- @since 0.1.0.0
class ProtoDatum a where
  -- | The type of protobuf literal used to represent a value of type @a@.
  --
  -- @since 0.1.0.0
  datumRep :: DatumRep

  -- | A type-safe cast operation from a 'DotProtoValue' literal to a value of
  -- the type @a@.
  --
  -- @since 0.1.0.0
  castDatum :: DotProtoValue -> Maybe a
  castDatum val = castDatumRepWith (datumRep @a) val
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
instance ProtoDatum Int where
  datumRep = DRepInteger

-- | @since 0.1.0.0
instance ProtoDatum String where
  datumRep = DRepString

-- | @since 0.1.0.0
instance ProtoDatum ByteString where
  datumRep = DRepString

  castDatum x = encodeUtf8 <$> castDatum @String x

-- | @since 0.1.0.0
instance ProtoDatum DotProtoIdentifier where
  datumRep = DRepIdent

-- Proto Names -----------------------------------------------------------------

-- | Splits a 'DotProtoIdentifier' into a list of the names that the identifier
-- is comprised of.
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

-- | Displays a 'DotProtoIdentifier' as a formatted string.
--
-- >>> showProtoId (DotProto.Dots (DotProto.Path ["package", "identifier"]))
-- "package.identifier"
--
-- @since 0.1.0.0
showProtoId :: DotProtoIdentifier -> String
showProtoId idt =
  let parts :: [String]
      parts = toProtoNameList idt
   in if null parts
        then "<anonymous>"
        else intercalate "." parts

-- Proto Options ---------------------------------------------------------------

-- | 'ProtoOptionSet' is a collection of protobuf options.
--
-- @since 0.1.0.0
newtype ProtoOptionSet = ProtoOptionSet
  {getProtoOptionSet :: Map DotProtoIdentifier DotProtoValue}
  deriving
    (Semigroup, Monoid)
    via Map DotProtoIdentifier DotProtoValue

-- | Inserts a protobuf options into the 'ProtoOptionSet'.
--
-- If an option with the same 'DotProtoIdentifier' is an element of the
-- 'ProtoOptionSet', then a 'ProtoOptionAlreadySet' error is raised.
--
-- @since 0.1.0.0
insertOption ::
  MonadError ProtoOptionError m =>
  DotProtoOption ->
  ProtoOptionSet ->
  m ProtoOptionSet
insertOption opt opts =
  let idt :: DotProtoIdentifier
      idt = DotProto.dotProtoOptionIdentifier opt
   in if memberOption idt opts
        then throwError (ProtoOptionAlreadySet idt)
        else pure (insertOption' opt opts)

-- | Inserts a protobuf options into the 'ProtoOptionSet'.
--
-- If an option with the same 'DotProtoIdentifier' is an element of the
-- 'ProtoOptionSet', then the associated 'DotProtoValue' is replaced.
--
-- @since 0.1.0.0
insertOption' :: DotProtoOption -> ProtoOptionSet -> ProtoOptionSet
insertOption' opt (ProtoOptionSet kvs) = do
  let key = DotProto.dotProtoOptionIdentifier opt
      val = DotProto.dotProtoOptionValue opt
   in ProtoOptionSet (Map.insert key val kvs)

-- | Lookup the 'DotProtoValue' set for a protobuf option by name.
--
-- @since 0.1.0.0
lookupOption :: DotProtoIdentifier -> ProtoOptionSet -> Maybe DotProtoValue
lookupOption key (ProtoOptionSet kvs) = Map.lookup key kvs

-- | Is an option with the 'DotProtoIdentifier' an element of the
-- 'ProtoOptionSet'.
--
-- @since 0.1.0.0
memberOption :: DotProtoIdentifier -> ProtoOptionSet -> Bool
memberOption key (ProtoOptionSet kvs) = Map.member key kvs

-- Proto Options - Option Errors -----------------------------------------------

-- | 'ProtoOptionError' represents the errors that improper protobuf option
-- usage can produce.
--
-- @since 0.1.0.0
data ProtoOptionError
  = -- | 'ProtoOptionAlreadySet' errors are emitted when protobuf declarations
    -- when multiple values are set for the same option.
    --
    -- @
    -- message BadMessage {
    --   option the_message_option = "b4d1d3a";
    --   option the_message_option = 1337;
    -- }
    -- @
    ProtoOptionAlreadySet DotProtoIdentifier
  | -- | 'OptionValueTypeMismatch' errors represents a mismatch between the
    -- type expected for an option and observed value the option was set to.
    --
    -- * 'DatumRep' expected type of value for the option.
    --
    -- * 'DotProtoOption' is the observed option.
    --
    -- @
    -- extend google.protobuf.MessageOptions {
    --   // The option "my_option" is expected to be a string.
    --   optional string my_option = 51234;
    -- }
    --
    -- message MyMessage {
    --   // Setting "my_option" to an integer value would produce a type error.
    --   option (my_option) = 1336;
    -- }
    -- @
    OptionValueTypeMismatch DatumRep DotProtoOption
  deriving stock (Data, Eq, Generic, Ord, Show, Typeable)

-- | @since 0.1.0.0
instance Exception ProtoOptionError where
  displayException (ProtoOptionAlreadySet idt) =
    "the option " ++ showProtoId idt ++ " was already set."
  displayException (OptionValueTypeMismatch rep opt) =
    let idt = DotProto.dotProtoOptionIdentifier opt
        val = DotProto.dotProtoOptionValue opt
     in "expected the value set for option "
          ++ showProtoId idt
          ++ " to have the type "
          ++ Show.shows rep ", instead it was set to "
          ++ Show.shows val "."
  {-# INLINE displayException #-}

-- Proto Files -----------------------------------------------------------------

-- | 'for'-style traversal over the 'ProtoServices' defined in a 'DotProto'.
--
-- @since 0.1.0.0
servicesOf :: Applicative f => DotProto -> (ProtoService -> f a) -> f [a]
servicesOf dotproto = for (getFileServices dotproto)

-- | Accesses the list of services defined in the 'DotProto'.
--
-- @since 0.1.0.0
getFileServices :: DotProto -> [ProtoService]
getFileServices dotproto =
  foldMap toService (DotProto.protoDefinitions dotproto)
  where
    toService :: DotProtoDefinition -> [ProtoService]
    toService (DotProto.DotProtoService _ idt ps) = [ProtoService idt ps]
    toService _ = []

-- | Accesses the 'ProtoOptionSet' of options set in the 'DotProto'.
--
-- If the 'DotProto' sets the same file-level option more than once, a
-- 'ProtoOptionAlreadySet' error is raised.
--
-- @since 0.1.0.0
getFileOptions :: MonadError ProtoOptionError m => DotProto -> m ProtoOptionSet
getFileOptions dotproto = foldrM insertOption mempty (DotProto.protoOptions dotproto)

-- Proto Services --------------------------------------------------------------

-- | 'ProtoService' is a record representing a protobuf service definition.
--
-- @since 0.1.0.0
data ProtoService = ProtoService
  { serviceName :: DotProtoIdentifier
  , serviceDefs :: [DotProtoServicePart]
  }
  deriving stock (Eq, Show)

-- | 'for'-style traversal over the 'RPCMethod' defined in a 'ProtoService'.
--
-- @since 0.1.0.0
methodsOf :: Applicative f => ProtoService -> (RPCMethod -> f a) -> f [a]
methodsOf dotproto = for (getServiceMethods dotproto)

-- | Accesses the 'RPCMethods' defined by a 'ProtoService'.
--
-- @since 0.1.0.0
getServiceMethods :: ProtoService -> [RPCMethod]
getServiceMethods (ProtoService _ ps) = foldr toRPCs mempty ps
  where
    toRPCs :: DotProtoServicePart -> [RPCMethod] -> [RPCMethod]
    toRPCs (DotProto.DotProtoServiceRPCMethod rpc) rpcs = rpc : rpcs
    toRPCs _ rpcs = rpcs

-- | Accesses the 'ProtoOptionSet' of options set in the 'ProtoService'.
--
-- If the 'ProtoService' sets the same service-level option more than once, a
-- 'ProtoOptionAlreadySet' error is thrown.
--
-- @since 0.1.0.0
getServiceOptions ::
  forall m.
  MonadError ProtoOptionError m =>
  ProtoService ->
  m ProtoOptionSet
getServiceOptions (ProtoService _ ps) = foldrM toOptions mempty ps
  where
    toOptions :: DotProtoServicePart -> ProtoOptionSet -> m ProtoOptionSet
    toOptions (DotProto.DotProtoServiceOption opt) opts = insertOption opt opts
    toOptions _ opts = pure opts

-- Proto Methods ---------------------------------------------------------------

-- | Querys a 'RPCMethod' for its gRPC method type.
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

-- | Accesses the 'ProtoOptionSet' of options set in the 'RPCMethod'.
--
-- If the 'RPCMethod' sets the same method-level option more than once, a
-- 'ProtoOptionAlreadySet' error is thrown.
--
-- @since 0.1.0.0
getMethodOptions :: MonadError ProtoOptionError m => RPCMethod -> m ProtoOptionSet
getMethodOptions rpc = foldrM insertOption mempty (DotProto.rpcMethodOptions rpc)

-- Proto Errors ----------------------------------------------------------------

-- | Displays a 'CompileError' in a legible format.
--
-- @since 0.1.0.0
showCompileError :: CompileError -> String
showCompileError = \case
  DotProto.CircularImport filepath ->
    let tagS = showErrorName 'DotProto.CircularImport
     in tagS ++ "circular imports in the file " ++ show filepath
  DotProto.CompileParseError err ->
    showEmbedded 'DotProto.CompileParseError "parse" (show err)
  DotProto.InternalError err ->
    showEmbedded 'DotProto.InternalError "internal" err
  DotProto.InvalidPackageName idt ->
    showIllegalId 'DotProto.InvalidPackageName "package" idt
  DotProto.InvalidMethodName idt ->
    showIllegalId 'DotProto.InvalidMethodName "method" idt
  DotProto.InvalidTypeName nm ->
    showIllegalName 'DotProto.InvalidTypeName "type" nm
  DotProto.InvalidMapKeyType str ->
    let tagS = showErrorName 'DotProto.InvalidMapKeyType
        strS = show str
     in tagS ++ "values of the type " ++ strS ++ " can not be used as map keys."
  DotProto.NoPackageDeclaration ->
    showErrorName 'DotProto.NoPackageDeclaration ++ "missing package declaration."
  DotProto.NoSuchType idt ->
    let tagS = showErrorName 'DotProto.NoSuchType
        idtS = "\"" ++ showProtoId idt ++ "\""
     in tagS ++ "no such type " ++ idtS ++ " in scope."
  DotProto.NonzeroFirstEnumeration enm idt n ->
    let tagS = showErrorName 'DotProto.NonzeroFirstEnumeration
        enmS = show enm
        idtS = "\"" ++ showProtoId idt ++ "\"" ++ " (field #" ++ show n ++ ")"
     in tagS ++ idtS ++ " in the enumeration " ++ enmS ++ " must be zero."
  DotProto.EmptyEnumeration str ->
    let tagS = showErrorName 'DotProto.EmptyEnumeration
        strS = show str
     in tagS ++ "the enumeration " ++ strS ++ " was defined without any fields."
  DotProto.Unimplemented str ->
    showEmbedded 'DotProto.Unimplemented "unimplemented" str
  where
    -- @ proto3-suite error: {1}: @
    showErrorName :: Name -> String
    showErrorName nm = "proto3-suite error: " ++ Show.shows nm ": "

    -- @ {2} error({1}): {3} @
    showEmbedded :: Name -> String -> String -> String
    showEmbedded nm ty msg = ty ++ " error(" ++ Show.shows nm "): " ++ msg

    -- @ proto3-suite error: {1}: illegal {2} identifier "{3}" @
    showIllegalId :: Name -> String -> DotProtoIdentifier -> String
    showIllegalId nm ty idt =
      showErrorName nm ++ "illegal " ++ ty ++ " identifier \"" ++ showProtoId idt ++ "\""

    -- @ proto3-suite error: {1}: illegal {2} name "{3}" @
    showIllegalName :: Name -> String -> String -> String
    showIllegalName nm ty str =
      showErrorName nm ++ "illegal " ++ ty ++ " name " ++ show str

-- | Displays a 'CompileError' in a legible format.
--
-- @since 0.1.0.0
showParseError :: ParseError -> String
showParseError = \case
  Wire.WireTypeError msg -> toString msg
  Wire.BinaryError msg -> toString msg
  Wire.EmbeddedError msg errM ->
    let ctxS :: String
        ctxS = toString msg
     in case errM of
          Nothing -> ctxS
          Just err -> ctxS ++ ": " ++ showParseError err
