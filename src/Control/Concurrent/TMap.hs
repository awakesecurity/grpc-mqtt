{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | TODO
--
-- @since 1.0.0
module Control.Concurrent.TMap
  ( -- * TMap
    TMap (TMap, getTMap),

    -- * Construction
    -- $tmap-construction
    empty,
    emptyIO,

    -- * Destruction
    -- $tmap-destruction
    toMap,
    toAscList,

    -- * Insertion
    -- $tmap-insertion
    insert,

    -- * Folding
    -- $tmap-folding
    ifoldr,
    ifoldMap,
    iany,
  )
where

--------------------------------------------------------------------------------

import Control.Concurrent.STM (STM)
import Control.Concurrent.STM.TVar (TVar, newTVar, readTVar, writeTVar)

import Data.IORef (IORef, newIORef, readIORef, atomicModifyIORef')

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

import GHC.Conc.Sync (unsafeIOToSTM)

--------------------------------------------------------------------------------

-- TMap ------------------------------------------------------------------------

-- | TODO
--
-- @since 1.0.0
newtype TMap k v = TMap
  {getTMap :: IORef (Map k (TVar v))}

-- TMap ------------------------------------------------------------------------

-- $tmap-construction
--
-- TODO

-- | TODO
--
-- @since 1.0.0
empty :: STM (TMap k v)
empty = unsafeIOToSTM emptyIO

-- | TODO
--
-- @since 1.0.0
emptyIO :: IO (TMap k v)
emptyIO = fmap TMap (newIORef Map.empty)

-- TMap ------------------------------------------------------------------------

-- $tmap-destruction
--
-- TODO

-- | TODO
--
-- @since 1.0.0
toMap :: TMap k v -> STM (Map k v)
toMap (TMap ref) = do
  kvs <- unsafeIOToSTM (readIORef ref)
  traverse readTVar kvs

-- | TODO
--
-- @since 1.0.0
toAscList :: TMap k v -> STM [(k, v)]
toAscList = ifoldr (\k v xs -> pure ((k, v) : xs)) []

-- TMap ------------------------------------------------------------------------

-- $tmap-insertion
--
-- TODO

-- | TODO
--
-- @since 1.0.0
insert :: Ord k => k -> v -> TMap k v -> STM ()
insert k x (TMap ref) = do
  kvs <- unsafeIOToSTM (readIORef ref)
  case Map.lookup k kvs of
    Nothing -> do
      var <- newTVar x
      unsafeIOToSTM do
        atomicModifyIORef' ref \xs ->
          (Map.insert k var xs, ())
    Just var -> do
      writeTVar var x

-- TMap ------------------------------------------------------------------------

-- $tmap-folding
--
-- TODO

-- | TODO
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

-- | TODO
--
-- @since 1.0.0
ifoldMap :: Monoid m => (k -> v -> m) -> TMap k v -> STM m
ifoldMap f = ifoldr (\k v -> pure . mappend (f k v)) mempty

-- | TODO
--
-- @since 1.0.0
iany :: forall k v. (k -> v -> STM Bool) -> TMap k v -> STM Bool
iany p =
  let run :: k -> v -> Bool -> STM Bool
      run k v xs = fmap (&& xs) (p k v)
   in ifoldr run True
