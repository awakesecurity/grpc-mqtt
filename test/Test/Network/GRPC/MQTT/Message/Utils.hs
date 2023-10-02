module Test.Network.GRPC.MQTT.Message.Utils where

import Relude

import Control.Concurrent.TOrderedQueue
  ( TOrderedQueue,
    SequenceId (SequenceId, Unordered),
    Sequenced (..),
    writeTOrderedQueue,
  )

mkSequencedSend :: (MonadIO m1, MonadIO m2) => TOrderedQueue a -> m1 (a -> m2 ())
mkSequencedSend queue = do
  indexVar <- newTVarIO (0 :: Natural)

  let indexedSend x = atomically do
        i <- readTVar indexVar
        modifyTVar' indexVar (+ 1)
        writeTOrderedQueue queue (Sequenced (SequenceId i) x)

  pure indexedSend

mkUnorderedSend :: (MonadIO m1, MonadIO m2) => TOrderedQueue a -> m1 (a -> m2 ())
mkUnorderedSend queue = do
  let unorderedSend x = atomically $ writeTOrderedQueue queue (Sequenced Unordered x)
  pure unorderedSend
