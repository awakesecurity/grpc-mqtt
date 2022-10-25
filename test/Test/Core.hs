
module Test.Core 
  ( mockPublish
  )
where 

import Control.Concurrent.STM.TQueue (TQueue, writeTQueue)

import Data.ByteString.Internal (ByteString, create, memcpy)
import Data.ByteString qualified as ByteString
import Data.ByteString.Internal qualified as ByteString.Internal

import Foreign.ForeignPtr (withForeignPtr)

import Relude

--------------------------------------------------------------------------------

mockPublish :: TQueue ByteString -> ByteString -> IO ()
mockPublish queue message = do
  let (ptr, _, _) = ByteString.Internal.toForeignPtr message
  let len = ByteString.length message 
  recv <- create len \recvPtr -> 
    withForeignPtr ptr \sendPtr ->
      memcpy recvPtr sendPtr len
  atomically (writeTQueue queue recv)