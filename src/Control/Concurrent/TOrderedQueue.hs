-- |
-- Module      :  Control.Concurrent.TOrderedQueue
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- Definitions for the 'TOrderedQueue' container.
--
-- @since 1.0.0
module Control.Concurrent.TOrderedQueue where

--------------------------------------------------------------------------------

import Relude

import Control.Concurrent.STM
  ( TQueue,
    newTQueue,
    newTQueueIO,
    retry,
    tryReadTQueue,
    writeTQueue,
  )

import Data.PQueue.Prio.Min (MinPQueue, insert, minViewWithKey)

data SequenceId
  = Unordered
  | SequenceId !Natural
  deriving stock (Eq, Ord, Show)

-- | A value `a` annotated with a `SequenceId`
data Sequenced a = Sequenced
  { idx :: !SequenceId
  , val :: !a
  }
  deriving stock (Show)

instance Eq (Sequenced a) where
  (==) = (==) `on` idx

instance Ord (Sequenced a) where
  (<=) = (<=) `on` idx

-- | A queue in which messages written to the queue can be annotated with a `SequenceId`, and messages read from
-- the queue will always be seen in order by `SequenceId`, even if the messages are written out-of-order.
-- Messages written to the queue annotated with `Unordered` will be read before any ordered messages and will be
-- processed in FIFO order.
data TOrderedQueue a
  = TOrderedQueue
      !(TVar Natural) -- Sequence counter indicating what the sequence id of the next message read should be
      !(TVar (MinPQueue Natural a)) -- A min heap for holding messages annotated by `SequenceId`
      !(TQueue a) -- A regular TQueue used for processing `Unordered` messages

-- | Build and return a new `TOrderedQueue`
newTOrderedQueue :: STM (TOrderedQueue a)
newTOrderedQueue =
  TOrderedQueue
    <$> newTVar 0
    <*> newTVar mempty
    <*> newTQueue

-- | `IO` version of `newTOrderedQueue`
newTOrderedQueueIO :: IO (TOrderedQueue a)
newTOrderedQueueIO = do
  TOrderedQueue
    <$> newTVarIO 0
    <*> newTVarIO mempty
    <*> newTQueueIO

-- | Write an item, annotated by `Sequenced`, to an `TOrderedQueue`
writeTOrderedQueue :: TOrderedQueue a -> Sequenced a -> STM ()
writeTOrderedQueue (TOrderedQueue _ orderedQueueVar unorderedQueue) (Sequenced sid x) =
  case sid of
    Unordered -> writeTQueue unorderedQueue x
    SequenceId i -> modifyTVar' orderedQueueVar (insert i x)

-- | Read the next item from the `TOrderedQueue`.
-- It will first return any `Unordered` items if one is available.
-- If no `Unordered` items are available, it will return the next item from the
-- ordered queue if the index matches that of the current sequence counter.
-- Otherwise blocks until an `Unordered` item is written, or an item with the correct
-- sequence id is written.
readTOrderedQueue :: TOrderedQueue a -> STM a
readTOrderedQueue otq@(TOrderedQueue seqVar orderedQueueVar unorderedQueue) =
  tryReadTQueue unorderedQueue >>= \case
    Just a -> pure a
    Nothing -> do
      orderedQueue <- readTVar orderedQueueVar
      case minViewWithKey orderedQueue of
        Nothing -> retry
        Just ((i, a), rest) -> do
          curSeq <- readTVar seqVar
          case i `compare` curSeq of
            -- If sequence number is less than current, it must be a duplicate,
            -- so we discard it and read again
            LT -> do
              writeTVar orderedQueueVar rest
              readTOrderedQueue otq
            EQ -> do
              writeTVar orderedQueueVar rest
              modifyTVar' seqVar (+ 1)
              pure a
            GT -> retry
