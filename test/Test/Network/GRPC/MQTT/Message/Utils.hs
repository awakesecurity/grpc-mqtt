module Test.Network.GRPC.MQTT.Message.Utils where

import Relude

import Control.Concurrent.OrderedTQueue
  ( Indexed (Indexed),
    OrderedTQueue,
    writeOrderedTQueue,
  )

mkIndexedSend :: (MonadIO m1, MonadIO m2) => OrderedTQueue a -> m1 (a -> m2 ())
mkIndexedSend queue = do
  indexVar <- newTVarIO (0 :: Int32)

  let indexedSend x = atomically do
        i <- readTVar indexVar
        modifyTVar' indexVar (+ 1)
        writeOrderedTQueue queue (Indexed i x)

  pure indexedSend
