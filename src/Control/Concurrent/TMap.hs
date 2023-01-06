
-- |
-- Module      :  Control.Concurrent.TMap
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see LICENSE
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- Definitions for the 'TMap' container.
--
-- @since 1.0.0
module Control.Concurrent.TMap
  ( -- * TMap
    TMap (TMap, getTMap),

    -- * Construction
    empty,
    emptyIO,

    -- * Destruction
    toAscList,

    -- * Insertion
    insert,

    -- * Deletion
    delete,

    -- * Query
    length,
    member,
    lookup,

    -- * Folding
    ifoldr,

    -- * Conversion
    elems,
  )
where

--------------------------------------------------------------------------------

import Data.Foldable qualified as Foldable

import Data.Map.Strict qualified as Map

import GHC.Conc.Sync (unsafeIOToSTM)

import Relude hiding (empty, length)

-- TMap ------------------------------------------------------------------------

-- | STM-specialized non-blocking 'Map' container.
--
-- @since 1.0.0
newtype TMap k v = TMap
  {getTMap :: IORef (Map k (TVar v))}

-- TMap - Construction ----------------------------------------------------------

-- | Constructs an empty 'TMap'.
--
-- @since 1.0.0
empty :: STM (TMap k v)
empty = unsafeIOToSTM emptyIO

-- | Like 'empty', constructs the empty 'TMap' in 'IO'.
--
-- @since 1.0.0
emptyIO :: IO (TMap k v)
emptyIO = fmap TMap (newIORef Map.empty)

-- TMap - Destruction -----------------------------------------------------------

-- | Converts a 'TMap' to a list of key-value pairs sorted in ascending key
-- order.
--
-- @since 1.0.0
toAscList :: TMap k v -> STM [(k, v)]
toAscList (TMap ref) = do
  kvs0 <- unsafeIOToSTM (readIORef ref)
  kvs1 <- traverse readTVar kvs0
  pure (Map.toAscList kvs1)

-- TMap - Insertion -------------------------------------------------------------

-- | Inserts a new key-value pair into the 'TMap'. If the 'TMap' already contains
-- then given key, the associated value will be replaced.
--
-- @since 1.0.0
insert :: Ord k => k -> v -> TMap k v -> STM ()
insert k x (TMap ref) = do
  kvs <- unsafeIOToSTM (readIORef ref)
  case Map.lookup k kvs of
    Nothing -> unsafeIOToSTM do
      var <- newTVarIO x
      atomicModifyIORef' ref \kvs' ->
        (Map.insert k var kvs', ())
    Just var -> do
      writeTVar var x

-- TMap - Deletion --------------------------------------------------------------

-- | Removes the value associated to the key. If the key is not a member 'TMap',
-- no change is made.
--
-- @since 1.0.0
delete :: Ord k => k -> TMap k v -> STM ()
delete k (TMap ref) = do
  kvs <- unsafeIOToSTM (readIORef ref)
  case Map.lookup k kvs of
    Nothing -> pure ()
    Just _ -> unsafeIOToSTM do
      atomicModifyIORef' ref \kvs' ->
        (Map.delete k kvs', ())

-- TMap - Query -----------------------------------------------------------------

-- | Return the number of elements in the 'TMap'.
--
-- @since 1.0.0
length :: TMap k v -> STM Int
length (TMap ref) = do
  kvs <- unsafeIOToSTM (readIORef ref)
  pure (Foldable.length kvs)

-- | Is the the key an element of the 'TMap'?
--
-- @since 1.0.0
member :: Ord k => k -> TMap k v -> STM Bool
member k (TMap ref) = do
  kvs <- unsafeIOToSTM (readIORef ref)
  pure (Map.member k kvs)

-- | Returns the value associated to the given key, if one exists.
--
-- @since 1.0.0
lookup :: Ord k => k -> TMap k v -> STM (Maybe v)
lookup k (TMap ref) = do
  kvs <- unsafeIOToSTM (readIORef ref)
  case Map.lookup k kvs of
    Nothing -> pure Nothing
    Just var -> fmap Just (readTVar var)

-- TMap - Folding ---------------------------------------------------------------

-- | Right-associative fold indexed by the map keys.
--
-- @since 1.0.0
ifoldr :: forall k v m. (k -> v -> m -> STM m) -> m -> TMap k v -> STM m
ifoldr cons nil (TMap ref) = do
  kvs <- unsafeIOToSTM (readIORef ref)
  Map.foldrWithKey' run (pure nil) kvs
  where
    run :: k -> TVar v -> STM m -> STM m
    run i var xs = do
      x <- readTVar var
      xs >>= cons i x

-- TMap - Conversion ------------------------------------------------------------

-- | Retrieves a list of all mapped values in a 'TMap'.
--
-- prop> elems kvs ~ map snd (toAscList kvs)
--
-- @since 1.0.0
elems :: TMap k v -> STM [v]
elems (TMap ref) = do
  kvs <- unsafeIOToSTM (readIORef ref)
  traverse readTVar (Map.elems kvs)
