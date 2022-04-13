-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.RemoteClient.Handler.ServerStream
  ( -- * TODO
    -- ServerStreamH (ServerStreamH, unServerStreamH),
  )
where

-- -------------------------------------------------------------------------------

import Network.GRPC.HighLevel (ClientCall, MetadataMap, StreamRecv)

-- -------------------------------------------------------------------------------

import Network.GRPC.MQTT.Request (Request)
-- import Network.GRPC.MQTT.Response (Response)

-- -------------------------------------------------------------------------------

-- | TODO: 'NormalH' is a remote client handler for unary gRPC requests.
--
-- @since 1.0.0
-- newtype ServerStreamH rqt rsp = ServerStreamH
--   { unServerStreamH ::
--       Request rqt ->
--       (ClientCall -> MetadataMap -> StreamRecv rsp -> IO ()) ->
--       IO (Response rsp)
--   }
