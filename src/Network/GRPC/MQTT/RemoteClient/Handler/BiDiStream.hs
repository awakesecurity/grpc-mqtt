-- | TODO
--
-- @since 1.0.0
module Network.GRPC.MQTT.RemoteClient.Handler.BiDiStream
  ( -- * TODO
    BiDiStreamH (BiDiStreamH, runBiDiStreamH),
  )
where

-- -------------------------------------------------------------------------------

import Network.GRPC.HighLevel (ClientCall, MetadataMap, StreamRecv, StreamSend)
import Network.GRPC.HighLevel.Client (TimeoutSeconds, WritesDone)

-- -------------------------------------------------------------------------------

import Network.GRPC.MQTT.Request (Request)
import Network.GRPC.MQTT.Response (Response)
import Network.GRPC.MQTT.Types (Batched)

-- -------------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
newtype BiDiStreamH rqt rsp = BiDiStreamH
  { runBiDiStreamH ::
      TimeoutSeconds ->
      MetadataMap ->
      (ClientCall -> MetadataMap -> StreamSend rsp -> StreamRecv rqt -> WritesDone -> IO ()) ->
      IO (BiDiStreamingResponse rsp)
  }
