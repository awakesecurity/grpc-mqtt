{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TemplateHaskellQuotes #-}

-- |
-- Module      :  Network.GRPC.MQTT.Option.CLevel
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see LICENSE
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- This module defines the 'CLevel' datatype. 'CLevel' represents a zstandard
-- compression level. Zstandard offers compression levels for controlling how 
-- the algorithm favors speed vs. compression ratio. The supported range for a
-- compression levels is from 1 to 22. See [the "introduction" section of the 
-- zstandard documentation] 
-- (https://raw.githack.com/facebook/zstd/release/doc/zstd_manual.html) for more
-- information regarding zstandard compression levels.
--
-- @since 1.0.0
module Network.GRPC.MQTT.Option.CLevel
  ( -- * CLevel
    CLevel (CLevel, getCLevel),

    -- * Construction
    fromCLevel,
    toCLevel,

    -- * Predicates
    isCLevel,

    -- * Show
    showMaybeCLevel,

    -- * Proto
    -- $clevel-proto
    toProtoValue,
    toPrimType,

    -- * Wire Format
    throwCLevelBoundsError,
  )
where

--------------------------------------------------------------------------------

import Codec.Compression.Zstd qualified as Zstd

import Data.Data (Data)

import Data.List qualified as List

import GHC.Prim (Proxy#, proxy#)

import Language.Haskell.TH.Ppr (Ppr, ppr)
import Language.Haskell.TH.PprLib qualified as Ppr
import Language.Haskell.TH.Syntax (Lift)

import Proto3.Suite.Class
  ( Finite (enumerate),
    Named (nameOf),
    Primitive (decodePrimitive, encodePrimitive, primType),
    Message,
  )
import Proto3.Suite.DotProto (DotProtoPrimType, DotProtoValue, Path)
import Proto3.Suite.DotProto qualified as DotProto

import Proto3.Wire.Class (ProtoEnum (fromProtoEnum, toProtoEnumMay))
import Proto3.Wire.Decode (ParseError, Parser)
import Proto3.Wire.Decode qualified as Decode
import Proto3.Wire.Encode qualified as Encode

import Relude

import Text.Show qualified as Show

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Proto
  ( DatumRep (DRepIdent),
    ProtoDatum,
    castDatum,
    datumRep,
  )

import Proto3.Wire.Decode.Extra qualified as Decode

-- CLevel ----------------------------------------------------------------------

-- | 'CLevel' is an enumeration capturing all compression levels that zstandard
-- supports. See ["Compression Levels" section](#zstd-compression-levels) for
-- documentation on zstandard's compression levels.
--
-- Constructing 'CLevel' should be done via 'toCLevel' unless the underlying
-- 'Int' value is known to always be between @1@ and @22@ (inclusively).
--
-- @since 1.0.0
newtype CLevel = CLevel {getCLevel :: Int32}
  deriving stock (Data, Eq, Generic, Lift, Ord)
  deriving anyclass (Message)

-- |
-- @'minBound' == 'CLevel' 1@
--
-- @'maxBound' == 'CLevel' 22@
--
-- @since 1.0.0
instance Bounded CLevel where
  minBound = CLevel 1
  maxBound = CLevel (fromIntegral @Int @Int32 Zstd.maxCLevel)

-- | @'show' ('CLevel' 10) == "CLEVEL_10"@
--
-- @since 1.0.0
instance Show CLevel where
  show (CLevel x) = "CLEVEL_" ++ show x

-- | @since 1.0.0
instance Ppr CLevel where
  ppr x = Ppr.text (show x)

-- | @since 1.0.0
instance ProtoEnum CLevel where
  toProtoEnumMay = toCLevel
  fromProtoEnum = fromCLevel

-- | @since 1.0.0
instance Finite CLevel where
  enumerate _ = map makeEnum [1 .. 22]
    where
      makeEnum :: IsString s => Int32 -> (s, Int32)
      makeEnum x = (show (CLevel x), x)

-- | @'nameOf' ('proxy#' :: 'Proxy#' 'CLevel') == \"CLevel\"@
--
-- @since 1.0.0
instance Named CLevel where
  nameOf _ = "CLevel"

-- | @since 1.0.0
instance Primitive CLevel where
  encodePrimitive = Encode.enum
  decodePrimitive = Decode.enum >>= either throwCLevelBoundsError pure
  primType = toPrimType

-- | @since 1.0.0
instance ProtoDatum CLevel where
  datumRep = DRepIdent

  castDatum val = do
    DotProto.Single nm <- castDatum val
    enum <- List.lookup nm (enumerate @CLevel proxy#)
    toProtoEnumMay enum

-- CLevel - Construction -------------------------------------------------------

-- | Convert a 'CLevel' value to an 'Integral' value.
--
-- @since 1.0.0
fromCLevel :: Integral a => CLevel -> a
fromCLevel (CLevel x) = fromIntegral x

-- | Constructs a 'CLevel' from an 'Integral' value, if the value corresponds to
-- compression level that is supported by zstandard, otherwise yields 'Nothing'.
--
-- @since 1.0.0
toCLevel :: Integral a => a -> Maybe CLevel
toCLevel n
  | isCLevel n = Just (CLevel (fromIntegral n))
  | otherwise = Nothing

-- CLevel - Predicates ---------------------------------------------------------

-- | Predicate that tests if a given integral value corresponds to a compression
--  level supported by zstandard.
--
-- @since 1.0.0
isCLevel :: Integral a => a -> Bool
isCLevel x = fromCLevel minBound <= x && x <= fromCLevel maxBound

-- CLevel - Show ---------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
showMaybeCLevel :: Maybe CLevel -> String
showMaybeCLevel x = maybe "CLEVEL_DISABLED" show x

-- CLevel - Proto --------------------------------------------------------------

-- $clevel-proto
--
-- The equivalent protocol buffer data representation for 'CLevel' is the
-- enumeration @enum CLevel@ defined in <proto/haskell/grpc/mqtt/clevel.proto>
-- located in the root source directory.
--
-- @
-- syntax = "proto3";
-- package haskell.grpc.mqtt;
--
-- enum CLevel {
--   option allow_alias = true;
--
--   CLEVEL_DISABLE = 0;
--   CLEVEL_UNKNOWN = 0;
--   CLEVEL_1 = 1;
--   ...
--   CLEVEL_21 = 21;
--   CLEVEL_22 = 22;
-- }
-- @

-- | Convert a 'CLevel' to it's 'DotProtoValue' representation.
--
-- >>> toProtoValue (CLevel 10)
-- Identifier (Single "CLEVEL_10")
--
-- @since 1.0.0
toProtoValue :: CLevel -> DotProtoValue
toProtoValue x = DotProto.Identifier (DotProto.Single (show x))

-- | The primitive protobuf type repesenting the protocol buffer data
-- representation of a 'CLevel' value.
--
-- >>> toPrimType proxy#
-- Named (Dots (Path {components = "haskell" :| ["grpc","mqtt","CLevel"]}))
--
-- @since 1.0.0
toPrimType :: Proxy# CLevel -> DotProtoPrimType
toPrimType p =
  let path :: Path
      path = DotProto.Path ["haskell", "grpc", "mqtt", nameOf @CLevel p]
   in DotProto.Named (DotProto.Dots path)

-- CLevel - Wire Format --------------------------------------------------------

-- | Throws a 'Decode.WireTypeError' 'ParseError' reporting that a 'CLevel'
-- failed to be deserialized because the parsed enum value was outside of the
-- supported range for compression levels.
--
-- @since 1.0.0
throwCLevelBoundsError :: Show a => a -> Parser i b
throwCLevelBoundsError x =
  let issue :: ParseError
      issue = Decode.WireTypeError ("CLevel invalid " <> show x <> " (out of bounds)")
   in Decode.throwE (Decode.wireErrorLabel ''CLevel issue)
