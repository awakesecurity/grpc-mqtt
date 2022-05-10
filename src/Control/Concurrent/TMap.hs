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
    emptyIO,

    -- * Destruction
    -- $tmap-destruction
    toAscListIO,

    -- * Insertion
    -- $tmap-insertion
    insert,
  )
where

--------------------------------------------------------------------------------

import Control.Concurrent.STM (STM, atomically)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, writeTVar)

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
emptyIO :: IO (TMap k v)
emptyIO = fmap TMap (newIORef Map.empty)

-- TMap ------------------------------------------------------------------------

-- $tmap-destruction
--
-- TODO

-- | TODO
--
-- @since 1.0.0
toAscListIO :: TMap k v -> IO [(k, v)]
toAscListIO (TMap ref) = do
  kvs <- readIORef ref
  atomically (Map.foldrWithKey' unpair (pure []) kvs)
  where
    unpair :: k -> TVar v -> STM [(k, v)] -> STM [(k, v)]
    unpair k var xs = do
      x <- readTVar var
      fmap ((k, x) :) xs

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
    Nothing -> unsafeIOToSTM do
      var <- newTVarIO x
      atomicModifyIORef' ref \xs ->
        (Map.insert k var xs, ())
    Just var -> do
      writeTVar var x
