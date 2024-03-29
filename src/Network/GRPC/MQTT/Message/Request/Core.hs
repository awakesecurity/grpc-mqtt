
-- |
-- Module      :  Network.GRPC.MQTT.Message.Request.Core
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- Core module defining the 'Request' type and 'Request' instances.
--
-- @since 1.0.0
module Network.GRPC.MQTT.Message.Request.Core
  ( -- * Request
    Request (Request, message, options, timeout, metadata),
  )
where

---------------------------------------------------------------------------------

import Data.Data (Data)

import Network.GRPC.HighLevel (MetadataMap)

import Relude

---------------------------------------------------------------------------------

-- Orphan instances @Data MetadataMap@ and @Ord MetadataMap@
import Network.GRPC.HighLevel.Orphans ()

import Network.GRPC.MQTT.Option (ProtoOptions)

-- Request ----------------------------------------------------------------------

-- | The 'Request' message type represents a (wrapped) client request, a
-- dictionary of gRPC metadata bound to the request, and properties configuring
-- how the request is handled.
--
-- @since 1.0.0
data Request msg = Request
  { -- | The request's 'message' is a type representing the protocol buffer
    -- message needed to perform the RPC call the client is requesting.
    message :: msg
  , -- | The gRPC-MQTT specific protobuf options relevant to this request.
    options :: ProtoOptions
  , -- | The request's 'timeout' is the timeout period in unit seconds the
    -- requested gRPC call has to finished before a deadline-exceeded error
    -- response is sent back to the client.
    timeout :: {-# UNPACK #-} !Int
  , -- | The request's 'metadata' is the metadata bound to a request,
    -- represented as a map associating 'ByteString' keys to a list of
    -- 'ByteString' values.
    --
    -- Keys registered in the 'metadata' map must only contain lowercase
    -- characters, digits 0-9, ".", "_", and "-". Otherwise, a gRPC exception
    -- will be raised when the 'Request' is published. The metadata values have
    -- no value restrictions.
    metadata :: MetadataMap
  }
  deriving stock (Eq, Ord, Show)
  deriving stock (Data, Generic, Typeable)

-- | @since 1.0.0
instance Functor Request where
  fmap f (Request x opts to ms) = Request (f x) opts to ms
  {-# INLINE fmap #-}
