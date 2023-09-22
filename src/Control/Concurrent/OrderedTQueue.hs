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

import Control.Concurrent.STM.TQueue
  ( TQueue,
    isEmptyTQueue,
    newTQueue,
    newTQueueIO,
    readTQueue,
    writeTQueue,
  )
import Data.SortedList qualified as SL

data Indexed a = Indexed
  { idx :: !Int32
  , val :: !a
  }
instance Eq (Indexed a) where
  (==) = (==) `on` idx

instance Ord (Indexed a) where
  (<=) = (<=) `on` idx

data OrderedTQueue a = OrderedTQueue (TVar Int32) (TVar (SL.SortedList (Indexed a))) (TQueue (Indexed a))

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

writeOrderedTQueue :: OrderedTQueue a -> Indexed a -> STM ()
writeOrderedTQueue (OrderedTQueue _ _ queue) = writeTQueue queue

isEmptyOrderedTQueue :: OrderedTQueue a -> STM Bool
isEmptyOrderedTQueue (OrderedTQueue _ _ queue) = isEmptyTQueue queue

readOrderedTQueue :: OrderedTQueue a -> STM a
readOrderedTQueue otq@(OrderedTQueue seqVar bufferVar queue) = do
  curSeq <- readTVar seqVar
  buffer <- readTVar bufferVar

  ia@Indexed{idx, val} <-
    case SL.uncons buffer of
      Just (ia, rest)
        | curSeq == idx ia -> writeTVar bufferVar rest $> ia
      _ -> readTQueue queue

  if idx < 0
    then return val
    else case idx `compare` curSeq of
      -- If sequence number is less than current, it must be a duplicate, so we discard it and read again
      LT -> readOrderedTQueue otq
      EQ -> modifyTVar' seqVar (+ 1) $> val
      GT -> modifyTVar' bufferVar (SL.insert ia) >> readOrderedTQueue otq
