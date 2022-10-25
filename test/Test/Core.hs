
module Test.Core 
  ( mockPublish
  )
where 

import Control.Concurrent.STM.TQueue (TQueue, writeTQueue)

import Data.ByteString.Internal (create, memcpy, toForeignPtr)
import Data.ByteString qualified as ByteString

import Foreign.ForeignPtr (withForeignPtr)

import Relude

--------------------------------------------------------------------------------

-- | 'mockPublish' is a helper function used to simulate publishing a packet 
-- over MQTT. This helper can be used to bridge the gap between sender and 
-- reader pairs such as 'Network.GRPC.MQTT.Message.Request.makeRequestReader' 
-- and 'Network.GRPC.MQTT.Message.Request.makeRequestSender' in tests without 
-- requiring a service to be initialized first.
mockPublish :: TQueue ByteString -> ByteString -> IO ()
mockPublish queue message = do
  let !(ptr, _, _) = toForeignPtr message
  let !len = ByteString.length message 

  -- Explicitly copies the bytestring's contents into a fresh allocation.
  -- This disconnects the bytestring content and the underlying 'ForeignPtr' 
  -- before writing it to the recieving end's 'TQueue'. This is desirable for 
  -- two reason:
  --
  -- 1. In real-world applications, the 'ByteString' obtained by the reader used 
  --    on recieving end of a MQTT publish and the 'ByteString' provided to the 
  --    MQTT publish function will never share the same allocation. Explicitly 
  --    cloning the content ensures that test cases respect this property. 
  --  
  -- 2. The packet publishing function 'makePacketSender' operates on memory 
  --    in-place. If the same 'ForeignPtr' is being used in 'makePacketSender' 
  --    serialization as is being used in packet reader, then tests will hang 
  --    indefinitely due to TMVar deadlock. 
  recv <- create len \recvPtr -> 
    withForeignPtr ptr \sendPtr ->
      memcpy recvPtr sendPtr len

  atomically (writeTQueue queue recv)