{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskellQuotes #-}

-- |
-- Module      :  Network.GRPC.MQTT.Option
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see LICENSE
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- This module defines the 'ProtoOptions' record and functions related to
-- protobuf options specific to gRPC-MQTT.
--
-- @since 1.0.0
module Network.GRPC.MQTT.Option
  ( -- * ProtoOptions
    ProtoOptions
      ( ProtoOptions,
        rpcBatchStream,
        rpcServerCLevel,
        rpcClientCLevel
      ),

    -- * Construction
    defaultProtoOptions,

    -- * Predicates
    isClientCompressed,
    isRemoteCompressed,

    -- * Proto
    toProtoType,

    -- * Wire Encoding
    wireEncodeProtoOptions,
    wireEncodeProtoOptions',
    wireBuildProtoOptions,

    -- * Wire Decoding
    wireDecodeProtoOptions,
    wireParseProtoOptions,

    -- * Re-exports
    Batched,
    CLevel,
  )
where

--------------------------------------------------------------------------------

import Data.Data (Data)
import Data.List qualified as List

import GHC.Prim (Proxy#, proxy#)

import Language.Haskell.TH.Syntax (Lift)

import Proto3.Suite.Class
  ( HasDefault (def),
    Message (decodeMessage, dotProto, encodeMessage),
    Named,
    Primitive (decodePrimitive, primType),
  )
import Proto3.Suite.DotProto (DotProtoField, DotProtoType)
import Proto3.Suite.DotProto qualified as DotProto

import Proto3.Wire (FieldNumber)
import Proto3.Wire.Decode (ParseError, Parser, RawField)
import Proto3.Wire.Decode qualified as Decode
import Proto3.Wire.Encode (MessageBuilder)
import Proto3.Wire.Encode qualified as Encode

import Relude

import Text.Show qualified as Show ()

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Option.Batched (Batched (Unbatched))
import Network.GRPC.MQTT.Option.CLevel (CLevel, fromCLevel)

import Proto3.Wire.Decode.Extra qualified as Decode

-- ProtoOptions ----------------------------------------------------------------

-- | 'ProtoOptions' is a record that represents values for each of the custom
-- proto3 options that are used by gRPC-MQTT.
--
-- @
-- // import the compression level enumeration "CLevel"
-- import "haskell/grpc/mqtt/clevel.proto";
--
-- message ProtoOptions {
--   bool rpc_batch_stream = 1;
--   haskell.grpc.mqtt.CLevel rpc_server_clevel = 2;
--   haskell.grpc.mqtt.CLevel rpc_client_clevel = 3;
-- }
-- @
--
-- @since 1.0.0
data ProtoOptions = ProtoOptions
  { -- | TODO
    rpcBatchStream :: Batched
  , -- | TODO
    rpcServerCLevel :: Maybe CLevel
  , -- | TODO
    rpcClientCLevel :: Maybe CLevel
  }
  deriving stock (Eq, Data, Generic, Lift, Ord, Show)
  deriving anyclass (Named)

-- | @since 1.0.0
instance Message ProtoOptions where
  encodeMessage = wireBuildProtoOptions

  decodeMessage = Decode.at wireParseProtoOptions

  dotProto = toProtoType

-- Construction ----------------------------------------------------------------

-- | The default options used at the file, service, and method level if no
-- options are set explicitly.
--
-- @since 1.0.0
defaultProtoOptions :: ProtoOptions
defaultProtoOptions =
  ProtoOptions
    { rpcBatchStream = Unbatched
    , rpcServerCLevel = Nothing
    , rpcClientCLevel = Nothing
    }

-- Predicates ------------------------------------------------------------------

-- | Is client-side message compression enabled?
--
-- @since 1.0.0
isClientCompressed :: ProtoOptions -> Bool
isClientCompressed opts = isJust (rpcClientCLevel opts)

-- | Is message compression enabled on the remote client?
--
-- @since 1.0.0
isRemoteCompressed :: ProtoOptions -> Bool
isRemoteCompressed opts = isJust (rpcServerCLevel opts)

-- Wire Encoding ---------------------------------------------------------------

-- | The protobuf type repesenting the protocol buffer data representation of a
-- 'CLevel' value.
--
-- @since 1.0.0
toProtoType :: Proxy# ProtoOptions -> [DotProtoField]
toProtoType _ =
  [ mkfield @Batched 1 "rpc_batch_stream"
  , mkfield @CLevel 2 "rpc_server_clevel"
  , mkfield @CLevel 3 "rpc_client_clevel"
  ]
  where
    mkfield :: forall a. Primitive a => FieldNumber -> String -> DotProtoField
    mkfield n nm =
      let prototy :: DotProtoType
          prototy = DotProto.Prim (primType @a proxy#)
       in DotProto.DotProtoField n prototy (DotProto.Single nm) [] ""

-- Wire Encoding ---------------------------------------------------------------

-- | Serializes a 'ProtoOptions' to a 'LByteString' in the wire binary format.
--
-- @since 1.0.0
wireEncodeProtoOptions :: ProtoOptions -> LByteString
wireEncodeProtoOptions = Encode.toLazyByteString . wireBuildProtoOptions 0

-- | Like 'wireEncodeProtoOptions', but returns a strict 'ByteString'.
--
-- @since 1.0.0
wireEncodeProtoOptions' :: ProtoOptions -> ByteString
wireEncodeProtoOptions' = toStrict . wireEncodeProtoOptions

-- | 'MessageBuilder' capable of serializing a 'ProtoOptions' field at the
-- 'FieldNumber' that the 'ProtoOptions' appears in the message.
--
-- To serialize a 'ProtoOptions' as a standalone message (rather than a field
-- embedded within a message), a 'FieldNumber' @0@ should be given.
--
-- @since 1.0.0
wireBuildProtoOptions :: FieldNumber -> ProtoOptions -> MessageBuilder
wireBuildProtoOptions n ProtoOptions{..} =
  let varints :: [Word64]
      varints = 
        [ fromIntegral (fromEnum rpcBatchStream)
        , maybe 0 fromCLevel rpcServerCLevel
        , maybe 0 fromCLevel rpcClientCLevel
        ]
   in Encode.packedVarints n varints

-- ProtoOptions - Wire Decoding ------------------------------------------------

-- | Decodes 'ProtoOptions' record from a 'ByteString'.
--
-- @since 1.0.0
wireDecodeProtoOptions :: ByteString -> Either ParseError ProtoOptions
wireDecodeProtoOptions = Decode.parse (Decode.at wireParseProtoOptions 0)

-- | Message field parser capable of deserializing a 'ProtoOptions' record.
--
-- @since 1.0.0
wireParseProtoOptions :: Parser RawField ProtoOptions
wireParseProtoOptions =
  Decode.catchE parseProtoOptions \err ->
    Decode.throwE (Decode.wireErrorLabel ''ProtoOptions err)
  where
    -- TODO: docs packed varints optimization
    parseProtoOptions :: Parser RawField ProtoOptions
    parseProtoOptions = do
      varints <- Decode.one (Decode.packedVarints @Word64) []
      let len = length varints

      when (len < 3) do
        let issue :: ParseError
            issue = Decode.WireTypeError ("expected 3 varints, got " <> show len)
         in Decode.throwE issue

      ProtoOptions
        <$> parsePrimWith def (varints List.!! 0)
        <*> parseCLevelWith (varints List.!! 1)
        <*> parseCLevelWith (varints List.!! 2)

    parsePrimWith :: forall a. Primitive a => a -> Word64 -> Parser RawField a
    parsePrimWith defval varint = Decode.Parser \_ ->
      let parser :: Parser RawField a
          parser = Decode.one decodePrimitive defval
       in Decode.runParser parser [Decode.VarintField varint]

    parseCLevelWith :: Word64 -> Parser RawField (Maybe CLevel)
    parseCLevelWith 0 = pure Nothing
    parseCLevelWith x = Decode.Parser \_ ->
      let parser :: Parser RawField (Maybe CLevel)
          parser = Decode.one (Just <$> decodePrimitive) Nothing
       in Decode.runParser parser [Decode.VarintField x]
