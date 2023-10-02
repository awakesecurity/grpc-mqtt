-- |
-- Module      :  Control.Concurrent.OrderedTQueue
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- Definitions for the 'OrderedTQueue' container.
--
-- @since 1.0.0
module Control.Concurrent.OrderedTQueue where

--------------------------------------------------------------------------------

import Relude

import Control.Concurrent.STM (TQueue, newTQueue, newTQueueIO, retry, tryReadTQueue, writeTQueue)

import Data.PQueue.Prio.Min (MinPQueue, insert, minViewWithKey)

data SequenceId
  = Unordered
  | SequenceId !Natural
  deriving stock (Eq, Ord, Show)

data Sequenced a = Sequenced
  { idx :: !SequenceId
  , val :: !a
  }
  deriving stock (Show)
instance Eq (Sequenced a) where
  (==) = (==) `on` idx

instance Ord (Sequenced a) where
  (<=) = (<=) `on` idx

data OrderedTQueue a = OrderedTQueue !(TVar Natural) !(TVar (MinPQueue Natural a)) !(TQueue a)

newOrderedTQueue :: STM (OrderedTQueue a)
newOrderedTQueue =
  OrderedTQueue
    <$> newTVar 0
    <*> newTVar mempty
    <*> newTQueue

newOrderedTQueueIO :: IO (OrderedTQueue a)
newOrderedTQueueIO = do
  OrderedTQueue
    <$> newTVarIO 0
    <*> newTVarIO mempty
    <*> newTQueueIO

writeOrderedTQueue :: OrderedTQueue a -> Sequenced a -> STM ()
writeOrderedTQueue (OrderedTQueue _ orderedQueueVar unorderedQueue) (Sequenced sid x) =
  case sid of
    Unordered -> writeTQueue unorderedQueue x
    SequenceId i -> modifyTVar' orderedQueueVar (insert i x)

readOrderedTQueue :: OrderedTQueue a -> STM a
readOrderedTQueue otq@(OrderedTQueue seqVar orderedQueueVar queue) =
  tryReadTQueue queue >>= \case
    Just a -> pure a
    Nothing -> do
      curSeq <- readTVar seqVar
      orderedQueue <- readTVar orderedQueueVar

      case minViewWithKey orderedQueue of
        Nothing -> retry
        Just ((i, a), rest) ->
          case i `compare` curSeq of
            -- If sequence number is less than current, it must be a duplicate,
            -- so we discard it and read again
            LT -> do
              writeTVar orderedQueueVar rest
              readOrderedTQueue otq
            EQ -> do
              writeTVar orderedQueueVar rest
              modifyTVar' seqVar (+ 1)
              pure a
            GT -> retry
