-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.RemoteClient.Handler.ClientNormal
  ( -- * TODO
    ClientNormalH (ClientNormalH, runClientNormalH),
  )
where

-- ------------------------------------------------------------------------------

import Data.Profunctor (Profunctor, lmap, rmap)

-- ------------------------------------------------------------------------------

import Network.GRPC.MQTT.Request (Request)
import Network.GRPC.MQTT.Response.Normal (NormalResponse)

-- ------------------------------------------------------------------------------

-- | TODO: 'ClientNormalH' is a remote client handler for unary gRPC requests.
--
-- @since 1.0.0
newtype ClientNormalH rqt rsp = ClientNormalH
  {runClientNormalH :: Request rqt -> IO (NormalResponse rsp) }

-- | @since 1.0.0
instance Functor (ClientNormalH rqt) where
  fmap f (ClientNormalH k) = ClientNormalH (fmap (fmap f) . k)
  {-# INLINE fmap #-}

-- | @since 1.0.0
instance Profunctor ClientNormalH where
  lmap f (ClientNormalH k) = ClientNormalH (k . fmap f)
  {-# INLINE lmap #-}

  rmap g (ClientNormalH k) = ClientNormalH (fmap (fmap g) . k)
  {-# INLINE rmap #-}
