{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | This module exports the 'Batched' datatype.
--
-- == Batched Streaming
--
-- If batching is enabled for a streaming RPC method, then streamed messages
-- will be accumulated and packed until 'Network.GRPC.MQTT.Core.mqttMsgSizeLimit'
-- would be exceeded, then each of the accumulated stream chunks are published as
-- a single aggregate message.
--
-- Batched streaming can improve performance if the messages being streamed are
-- small (relative to 'Network.GRPC.MQTT.Core.mqttMsgSizeLimit') and are produced
-- in quick succession. Batching should not be enabled for streams that publish
-- infrequently (long-poll) since the additional buffering may prevent messages
-- from being published immediately.
--
-- == Protobuf Options
--
-- In @*.proto@ files, 'Batched' options are represented as a booleans. Batching
-- is toggled for a streaming RPC by setting @hs_grpc_mqtt_batched_stream@
-- option in a RPC. By default, streams are unbatched.
--
-- @
-- // Enable client-side batched streaming for the HelloRequest message
-- rpc LotsOfGreetings(stream HelloRequest) returns (HelloResponse) {
--   option hs_grpc_mqtt_batched_stream = true;
-- };
-- @
--
-- If @hs_grpc_mqtt_batched_stream@ is enabled for a bidirectionally streaming
-- RPC, both the client and server message streams will be batched. Enabling
-- batching has no effect on unary RPC methods.
--
-- Additionally, the options @hs_grpc_mqtt_default_batched_stream_file@ and
-- @hs_grpc_mqtt_default_batched_stream_service@ are avaliable. These options set
-- the default value of @hs_grpc_batched_stream@ at the file and service level,
-- respectively. If conflicting values are set for any of options used to
-- configure stream batching, then precedence is given to the value of the option
-- with the more granular scope.
--
-- @
-- // Enables batching by default for all services' RPCs in the file.
-- option hs_grpc_mqtt_default_batched_stream_file = true;
--
-- service HelloService {
--   // Overrides file-level value, disabling batching by default for all RPCs
--   // in HelloService.
--   option hs_grpc_mqtt_default_batched_stream_service = false;
-- };
-- @
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Option.Batched
  ( -- * Batched
    -- $option-batched
    Batched (Batch, Batched, Unbatched, getBatched)
  )
where

---------------------------------------------------------------------------------

import Data.Data (Data)

import Language.Haskell.TH.Syntax (Lift)

import Relude

import Proto3.Suite.Class (HasDefault, Primitive, def)

import Text.Show qualified as Show

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Proto (ProtoDatum)

-- Batched ----------------------------------------------------------------------

-- | 'Batched' is a boolean indicating whether gRPC streams should batch packets
-- before publishing over MQTT.
--
-- @since 0.1.0.0
newtype Batched = Batch {getBatched :: Bool}
  deriving newtype (Eq, Ord, Primitive)
  deriving stock (Data, Generic, Lift, Typeable)

-- | Pattern synonym for enabled batching.
--
-- @'Batched' == 'Batch' 'True'@
--
-- @since 0.1.0.0
pattern Batched :: Batched
pattern Batched = Batch True

-- | Pattern synonym for disabled batching.
--
-- @'Batched' == 'Batch' 'False'@
--
-- @since 0.1.0.0
pattern Unbatched :: Batched
pattern Unbatched = Batch False

{-# COMPLETE Batched, Unbatched #-}

-- |
-- @'maxBound' == 'Unbatched'@
--
-- @'maxBound' == 'Batched'@
--
-- @since 0.1.0.0
instance Bounded Batched where
  minBound = Unbatched
  maxBound = Batched

-- | @since 0.1.0.0
instance Enum Batched where
  toEnum x = Batch (x == 1)

  fromEnum Unbatched = 0
  fromEnum Batched = 1

-- | @'def' == 'Unbatched'@
--
-- @since 0.1.0.0
instance HasDefault Batched where
  def = Unbatched

-- | @since 0.1.0.0
instance Show Batched where
  show Unbatched = "Unbatched"
  show Batched = "Batched"
