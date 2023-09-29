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
module Control.Concurrent.OrderedTQueue3 where

--------------------------------------------------------------------------------

import Relude

import Control.Concurrent.STM (retry)
import Data.PQueue.Min

data Indexed a = Indexed
  { idx :: !Int32
  , val :: !a
  }
  deriving stock (Show)
instance Eq (Indexed a) where
  (==) = (==) `on` idx

instance Ord (Indexed a) where
  (<=) = (<=) `on` idx

data OrderedTQueue a = OrderedTQueue (TVar Int32) (TVar (MinQueue (Indexed a)))

newOrderedTQueue :: STM (OrderedTQueue a)
newOrderedTQueue =
  OrderedTQueue
    <$> newTVar 0
    <*> newTVar mempty

newOrderedTQueueIO :: IO (OrderedTQueue a)
newOrderedTQueueIO = do
  OrderedTQueue
    <$> newTVarIO 0
    <*> newTVarIO mempty

writeOrderedTQueue :: OrderedTQueue a -> Indexed a -> STM ()
writeOrderedTQueue (OrderedTQueue _ queueVar) x = modifyTVar' queueVar (insert x)

readOrderedTQueue :: OrderedTQueue a -> STM a
readOrderedTQueue otq@(OrderedTQueue seqVar queueVar) = do
  curSeq <- readTVar seqVar
  queue <- readTVar queueVar

  case minView queue of
    Just (ia, rest) ->
      case idx ia `compare` curSeq of
        LT -> do
          -- If sequence number is less than current, it must be a duplicate, so we discard it and read again
          writeTVar queueVar rest
          readOrderedTQueue otq
        EQ -> do
          writeTVar queueVar rest
          modifyTVar' seqVar (+ 1)
          pure (val ia)
        GT -> retry
    Nothing -> retry
