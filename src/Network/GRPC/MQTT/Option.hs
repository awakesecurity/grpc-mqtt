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

import Proto3.Suite
  ( Message (decodeMessage, dotProto, encodeMessage),
    Named,
    Primitive (primType),
  )

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

-- Batched ----------------------------------------------------------------------

-- $option-batched
--
-- Documentation on the 'Batched' protobuf option and details on batched
-- streams, can be foud in the "Network.GRPC.MQTT.Option.Batched" module.

-- CLevel -----------------------------------------------------------------------

-- $option-clevel
--
-- TODO
