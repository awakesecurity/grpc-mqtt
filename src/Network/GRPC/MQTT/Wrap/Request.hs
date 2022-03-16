-- | TODO:
--
-- @since 1.0.0
module Network.GRPC.MQTT.Wrap.Request
  ( -- * Requests
    Request (Request),
    rqtTimeout,
    rqtMetaMap,
    rqtPayload,
  )
where

import Network.GRPC.HighLevel (MetadataMap)
import Proto3.Suite (HasDefault (def), Message, Named (nameOf))

-- imports @instance 'Message' 'MetadataMap'@
import Network.GRPC.HighLevel.Orphans ()

-- -----------------------------------------------------------------------------

-- | TODO:
--
-- @since 1.0.0
data Request = Request
  { rqtTimeout :: {-# UNPACK #-} !Int64
  , rqtMetaMap :: MetadataMap
  , rqtPayload :: ByteString
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (Message)

-- | >>> nameOf (proxy# :: Request)
--   "Request"
--
-- @since 1.0.0
instance Named Request where
  nameOf _ = "Request"
  {-# INLINE CONLIKE nameOf #-}

-- | prop> def @Request == Request 0 mempty mempty
--
-- @since 1.0.0
instance HasDefault Request where
  def = Request 0 mempty mempty
  {-# INLINE CONLIKE def #-}
