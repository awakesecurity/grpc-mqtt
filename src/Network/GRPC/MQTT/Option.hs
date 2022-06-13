{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskellQuotes #-}

-- | TODO
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Option
  ( -- * ProtoOptions
    ProtoOptions
      ( ProtoOptions,
        rpcBatchStream,
        rpcServerCLevel,
        rpcClientCLevel
      ),

    -- ** Wire Encoding
    wireEncodeProtoOptions,
    wireEncodeProtoOptions',
    wireBuildProtoOptions,

    -- ** Wire Decoding
    wireDecodeProtoOptions,
    wireParseProtoOptions,

    -- * Batched
    -- $option-batched
    Batched (Batch, Batched, Unbatched, getBatched),

    -- * CLevel
    -- $option-clevel
    CLevel (CLevel, getCLevel),
    fromCLevel,
    toCLevel,
  )
where

---------------------------------------------------------------------------------

import Data.Data (Data)

import GHC.Prim (Proxy#, proxy#)

import Data.List qualified as List
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Data.Vector.Mutable qualified as MVector

import Proto3.Suite
  ( Message (decodeMessage, dotProto, encodeMessage),
    Named,
    Primitive (primType),
  )
import Proto3.Suite.DotProto (DotProtoField, DotProtoIdentifier, DotProtoType)
import Proto3.Suite.DotProto qualified as DotProto

import Proto3.Wire (FieldNumber)
import Proto3.Wire.Decode (ParseError, Parser, RawField, RawMessage)
import Proto3.Wire.Decode qualified as Decode
import Proto3.Wire.Encode (MessageBuilder)
import Proto3.Wire.Encode qualified as Encode

import Relude

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Option.Batched
  ( Batched (Batch, Batched, Unbatched, getBatched),
  )
import Network.GRPC.MQTT.Option.CLevel
  ( CLevel (CLevel, getCLevel),
    fromCLevel,
    toCLevel,
  )
import Network.GRPC.MQTT.Option.CLevel qualified as CLevel

import Proto3.Wire.Decode.Extra qualified as Decode

-- ProtoOptions -----------------------------------------------------------------

-- | TODO
--
-- @
-- // import the compression level enumeration "CLevel"
-- import "haskell/grpc/mqtt/clevel.proto";
--
-- message ProtoOptions {
--   bool rpc_batch_stream = 1;
--   haskell.grpc.mqtt.CLevel rpc_server_clevel = 2;
--   haskell.grpc.mqtt.CLevel rpc_client_clevel = 3;
--   uint64 rpc_timeout = 4;
-- }
-- @
--
-- @since 0.1.0.0
data ProtoOptions = ProtoOptions
  { rpcBatchStream :: Batched
  , rpcServerCLevel :: Maybe CLevel
  , rpcClientCLevel :: Maybe CLevel
  }
  deriving stock (Eq, Data, Generic, Ord, Show, Typeable)
  deriving anyclass (Named)

-- | @since 0.1.0.0
instance Message ProtoOptions where
  encodeMessage n opts = wireBuildProtoOptions n opts

  decodeMessage n = Decode.at wireParseProtoOptions n

  dotProto _ =
    [ newField 1 "rpc_batch_stream" (proxy# @Batched)
    , newField 2 "rpc_server_clevel" (proxy# @CLevel)
    , newField 3 "rpc_client_clevel" (proxy# @CLevel)
    , newField 4 "rpc_timeout" (proxy# @Word64)
    ]
    where
      newField :: Primitive a => FieldNumber -> String -> Proxy# a -> DotProtoField
      newField n nm px =
        let protoid :: DotProtoIdentifier
            protoid = DotProto.Dots (DotProto.Path ["haskell", "grpc", "mqtt", nm])

            prototy :: DotProtoType
            prototy = DotProto.Prim (primType px)
         in DotProto.DotProtoField n prototy protoid [] ""

-- ProtoOptions - Wire Encoding -------------------------------------------------

-- | Serializes a 'ProtoOptions' to a 'LByteString' in the wire binary format.
--
-- @since 0.1.0.0
wireEncodeProtoOptions :: ProtoOptions -> LByteString
wireEncodeProtoOptions opts =
  let builder :: MessageBuilder
      builder = wireBuildProtoOptions 0 opts
   in Encode.toLazyByteString builder

-- | Like 'wireEncodeProtoOptions', but returns a strict 'ByteString'.
--
-- @since 0.1.0.0
wireEncodeProtoOptions' :: ProtoOptions -> ByteString
wireEncodeProtoOptions' opts = toStrict (wireEncodeProtoOptions opts)

-- | 'MessageBuilder' capable of serializing a 'ProtoOptions' field at the
-- 'FieldNumber' that the 'ProtoOptions' appears in the message.
--
-- To serialize a 'ProtoOptions' as a standalone message (rather than a field
-- embedded within a message), a 'FieldNumber' @0@ should be given.
--
-- @since 0.1.0.0
wireBuildProtoOptions :: FieldNumber -> ProtoOptions -> MessageBuilder
wireBuildProtoOptions n ProtoOptions{..} =
  let varints :: Vector Word64
      varints = Vector.create do
        mvec <- MVector.new 3
        MVector.write mvec 0 (w64FromBatched rpcBatchStream)
        MVector.write mvec 1 (w64FromCLevel rpcServerCLevel)
        MVector.write mvec 2 (w64FromCLevel rpcClientCLevel)
        pure mvec
   in Encode.packedVarintsV id n varints
  where
    w64FromBatched :: Batched -> Word64
    w64FromBatched Unbatched = 0
    w64FromBatched Batched = 1

    w64FromCLevel :: Maybe CLevel -> Word64
    w64FromCLevel Nothing = 0
    w64FromCLevel (Just x) = CLevel.fromCLevel x

-- ProtoOptions - Wire Decoding -------------------------------------------------

-- | Decodes 'ProtoOptions' record from a 'ByteString'.
--
-- @since 0.1.0.0
wireDecodeProtoOptions :: ByteString -> Either ParseError ProtoOptions
wireDecodeProtoOptions bytes =
  let parseMessage :: Parser RawMessage ProtoOptions
      parseMessage = Decode.at wireParseProtoOptions 0
   in Decode.parse parseMessage bytes

-- | Message field parser capable of deserializing a 'ProtoOptions' record.
--
-- @since 0.1.0.0
wireParseProtoOptions :: Parser RawField ProtoOptions
wireParseProtoOptions =
  Decode.catchE parseProtoOptions \err ->
    let labelled :: ParseError
        labelled = Decode.wireErrorLabel ''ProtoOptions err
     in Decode.throwE labelled
  where
    -- TODO: docs packed varints optimization
    parseProtoOptions :: Parser RawField ProtoOptions
    parseProtoOptions = do
      varints <- Decode.one (Decode.packedVarints @Word64) []

      when (length varints < 4) do
        throwMissingFields (length varints)

      ProtoOptions
        <$> parseFieldBatched (varints List.!! 0)
        <*> parseFieldCLevel (varints List.!! 1)
        <*> parseFieldCLevel (varints List.!! 2)

    parseFieldBatched :: Word64 -> Parser RawField Batched
    parseFieldBatched 1 = pure Batched
    parseFieldBatched _ = pure Unbatched

    -- 'CLevel' is bounded from @1@ to @22@. Here the additional case for
    -- @0 :: Word64@ is interpreted as 'Nothing' for the case that a compression
    -- option is set to the @CLEVEL_NONE@ enum to disable compression.
    parseFieldCLevel :: Word64 -> Parser RawField (Maybe CLevel)
    parseFieldCLevel 0 = pure Nothing
    parseFieldCLevel x =
      case CLevel.toCLevel x of
        Nothing -> CLevel.throwCLevelBoundsError x
        Just x' -> pure (Just x')

    throwMissingFields :: Int -> Parser RawField a
    throwMissingFields n =
      let issue :: ParseError
          issue = Decode.WireTypeError ("expected 3 varints, got " <> show n)
       in Decode.throwE issue

-- Batched ----------------------------------------------------------------------

-- $option-batched
--
-- Documentation on the 'Batched' protobuf option and details on batched
-- streams, can be foud in the "Network.GRPC.MQTT.Option.Batched" module.

-- CLevel -----------------------------------------------------------------------

-- $option-clevel
--
-- TODO
