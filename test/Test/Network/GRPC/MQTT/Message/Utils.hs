module Test.Network.GRPC.MQTT.Message.Utils where

import Relude

import Control.Concurrent.OrderedTQueue
  ( OrderedTQueue,
    SequenceId (SequenceId, Unordered),
    Sequenced (..),
    writeOrderedTQueue,
  )

mkSequencedSend :: (MonadIO m1, MonadIO m2) => OrderedTQueue a -> m1 (a -> m2 ())
mkSequencedSend queue = do
  indexVar <- newTVarIO (0 :: Natural)

  let indexedSend x = atomically do
        i <- readTVar indexVar
        modifyTVar' indexVar (+ 1)
        writeOrderedTQueue queue (Sequenced (SequenceId i) x)

  pure indexedSend

mkUnorderedSend :: (MonadIO m1, MonadIO m2) => OrderedTQueue a -> m1 (a -> m2 ())
mkUnorderedSend queue = do
  let unorderedSend x = atomically $ writeOrderedTQueue queue (Sequenced Unordered x)
  pure unorderedSend
