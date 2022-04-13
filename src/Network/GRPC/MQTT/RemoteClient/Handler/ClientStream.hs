-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.RemoteClient.Handler.ClientStream
  ( -- * TODO
    ClientStreamH (ClientStreamH, runClientStreamH),
  )
where

-- -------------------------------------------------------------------------------

import Data.Profunctor (Profunctor, lmap, rmap)

import Network.GRPC.HighLevel (MetadataMap, StreamSend)
import Network.GRPC.HighLevel.Client (TimeoutSeconds)

-- -------------------------------------------------------------------------------

import Network.GRPC.MQTT.Response.ClientStreaming (ClientStreamingResponse)

-- -------------------------------------------------------------------------------

-- | TODO: 'NormalH' is a remote client handler for unary gRPC requests.
--
-- @since 1.0.0
newtype ClientStreamH rqt rsp = ClientStreamH
  { runClientStreamH ::
      TimeoutSeconds ->
      MetadataMap ->
      (StreamSend rqt -> IO ()) ->
      IO (ClientStreamingResponse rsp)
  }

-- | @since 1.0.0
instance Functor (ClientStreamH rqt) where
  fmap f (ClientStreamH k) =
    ClientStreamH \timeout metadata ssend ->
      fmap (fmap f) (k timeout metadata ssend)
  {-# INLINE fmap #-}

-- | @since 1.0.0
instance Profunctor ClientStreamH where
  lmap f (ClientStreamH k) =
    ClientStreamH \timeout metadata ssend ->
      k timeout metadata (ssend . lmap f)
  {-# INLINE lmap #-}

  rmap g (ClientStreamH k) =
    ClientStreamH \timeout metadata ssend ->
      fmap (fmap g) (k timeout metadata ssend)
  {-# INLINE rmap #-}
