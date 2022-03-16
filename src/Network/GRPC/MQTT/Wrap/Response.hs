-- |
--
-- @since 1.0.0
module Network.GRPC.MQTT.Wrap.Response
  ( -- * Responses
    Response (Response),
    rspBody,
    rspInitMetamap,
    rspTrailMetamap,
    rspCode,
    rspDetails,
  )
where

import Network.GRPC.HighLevel (MetadataMap, StatusCode (StatusUnknown))
import Proto3.Suite (HasDefault (def), Message, Named (nameOf))

-- imports @instance 'Message' 'MetadataMap'@
import Network.GRPC.HighLevel.Orphans ()

-- -----------------------------------------------------------------------------

data Response = Response
  { rspBody :: ByteString
  , rspInitMetamap :: MetadataMap
  , rspTrailMetamap :: MetadataMap
  , rspCode :: {-# UNPACK #-} !Int32
  , rspDetails :: Text -- TODO: make strict
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (Message)

-- | >>> nameOf (proxy# :: Response)
--   "Response"
--
-- @since 1.0.0
instance Named Response where
  nameOf _ = "Response"
  {-# INLINE CONLIKE nameOf #-}

-- | 'Response' defaults with all empty fields and an unknown response code (2).
--
-- prop> def @Response = Response mempty mempty mempty 2 mempty
--
-- @since 1.0.0
instance HasDefault Response where
  def =
    let codeUnkn :: Int32
        codeUnkn = fromIntegral (fromEnum StatusUnknown)
     in Response mempty mempty mempty codeUnkn mempty
  {-# INLINE CONLIKE def #-}
