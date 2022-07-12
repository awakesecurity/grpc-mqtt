module Network.GRPC.MQTT.Serial
  ( -- * Wire Encoding Options
    WireEncodeOptions (WireEncodeOptions, encodeCLevel, encodeBatched),

    -- ** Construction
    defaultEncodeOptions,
    makeClientEncodeOptions,
    makeRemoteEncodeOptions,

    -- ** predicates
    isEncodeCompressed,

    -- * Wire Decoding Options
    WireDecodeOptions (WireDecodeOptions, decodeDecompress),

    -- ** Construction
    defaultDecodeOptions,
    makeClientDecodeOptions,
    makeRemoteDecodeOptions,

    -- ** predicates
    isDecodeCompressed,
  )
where

--------------------------------------------------------------------------------

import Data.Data (Data)

import Language.Haskell.TH.Syntax (Lift)

import Relude

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Option (Batched, CLevel, ProtoOptions)
import Network.GRPC.MQTT.Option qualified as Option
import Network.GRPC.MQTT.Option.Batched qualified as Batched

-- Wire Encoding Options -------------------------------------------------------

-- | 'WireEncodeOptions' is a collection of settings that describe how protobuf
-- messages (instances of 'Message') should be serialized into the wire binary
-- format.
--
-- @since 0.1.0.0
data WireEncodeOptions = WireEncodeOptions
  { -- | If given, 'encodeCLevel' is the zstandard compression level that is
    -- used for compressing a protobuf message after it has been serialized.
    --
    --  No compression is applied to the serialized message in the case that
    -- @'encodeCLevel' == 'Nothing'@
    encodeCLevel :: Maybe CLevel
  , -- | 'encodeBatched' toggles batching when the serialized protobuf messages
    -- are published by a streaming RPC method type.
    encodeBatched :: Batched
  }
  deriving stock (Data, Eq, Ord, Lift, Show, Typeable)

-- Wire Encoding Options - Construction ----------------------------------------

-- | TODO
--
-- @since 0.1.0.0
defaultEncodeOptions :: WireEncodeOptions
defaultEncodeOptions =
  WireEncodeOptions
    { encodeCLevel = Nothing
    , encodeBatched = Batched.Unbatched
    }
{-# INLINE CONLIKE defaultEncodeOptions #-}

-- | Obtain the wire encoding options that should be used client-side from a
-- 'ProtoOptions' record.
--
-- @since 0.1.0.0
makeClientEncodeOptions :: ProtoOptions -> WireEncodeOptions
makeClientEncodeOptions opts =
  WireEncodeOptions
    { encodeCLevel = Option.rpcClientCLevel opts
    , encodeBatched = Option.rpcBatchStream opts
    }

-- | Obtain the wire encoding options that should be used by the remote client
-- from a 'ProtoOptions' record.
--
-- @since 0.1.0.0
makeRemoteEncodeOptions :: ProtoOptions -> WireEncodeOptions
makeRemoteEncodeOptions opts =
  WireEncodeOptions
    { encodeCLevel = Option.rpcServerCLevel opts
    , encodeBatched = Option.rpcBatchStream opts
    }

-- Wire Encoding Options - Predicates ------------------------------------------

-- | Is compression enabled for the 'WireEncodeOptions'?
--
-- @since 0.1.0.0
isEncodeCompressed :: WireEncodeOptions -> Bool
isEncodeCompressed options = isJust (encodeCLevel options)

-- Wire Decoding Options -------------------------------------------------------

-- | 'WireDecodeOptions' is a collection of settings that describe how protobuf
-- messages (instances of 'Message') should be deserialized from the wire binary
-- format.
newtype WireDecodeOptions = WireDecodeOptions
  { -- | 'decodeDecompress' toggles whether zstandard decompression should be
    -- applied to a 'ByteString' before it is parsed during deserialization.
    decodeDecompress :: Bool
  }
  deriving stock (Data, Eq, Ord, Lift, Show, Typeable)

-- Wire Decoding Options - Construction ----------------------------------------

-- | TODO
--
-- @since 0.1.0.0
defaultDecodeOptions :: WireDecodeOptions
defaultDecodeOptions =
  WireDecodeOptions
    { decodeDecompress = False
    }
{-# INLINE CONLIKE defaultDecodeOptions #-}

-- | Obtain the wire decoding options that should be used client-side from a
-- 'ProtoOptions' record.
makeClientDecodeOptions :: ProtoOptions -> WireDecodeOptions
makeClientDecodeOptions opts =
  WireDecodeOptions
    { decodeDecompress = Option.isClientCompressed opts
    }

-- | Obtain the wire decoding options that should be used by the remote client
-- from a 'ProtoOptions' record.
makeRemoteDecodeOptions :: ProtoOptions -> WireDecodeOptions
makeRemoteDecodeOptions opts =
  WireDecodeOptions
    { decodeDecompress = Option.isRemoteCompressed opts
    }

-- Wire Encoding Options - Predicates ------------------------------------------

-- | Is decompression enabled for the 'WireDecodeOptions'?
--
-- @since 0.1.0.0
isDecodeCompressed :: WireDecodeOptions -> Bool
isDecodeCompressed options = decodeDecompress options