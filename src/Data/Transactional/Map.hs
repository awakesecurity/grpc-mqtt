{-# LANGUAGE NoImplicitPrelude #-}

-- |
--
-- @since 1.0.0
module Data.Transactional.Map
  ( -- * Transactional Maps
    TMap (TMap),

    -- ** Construction
    empty,
    emptyIO,
    singleton,
    singletonIO,

    -- ** Insertion
    insert,

    -- ** Query
    lookup,

    -- ** Conversion

    -- *** Map
    freeze,
  )
where

import Control.Applicative (pure)
import Control.Concurrent.STM (STM, atomically)
import Control.Concurrent.STM.TVar (TVar)
import Control.Concurrent.STM.TVar qualified as TVar

import Data.Functor ((<$>))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (Maybe (Just, Nothing))
import Data.Kind (Type)
import Data.Ord (Ord)
import Data.Traversable (traverse)

import System.IO (IO)

-- -----------------------------------------------------------------------------

newtype TMap (k :: Type) (v :: Type) :: Type where
  TMap :: TVar (Map k (TVar v)) -> TMap k v

-- -----------------------------------------------------------------------------
--
-- Construction
--

-- | TODO:
--
-- @since 1.0.0
empty :: STM (TMap k v)
empty = TMap <$> TVar.newTVar Map.empty

-- | TODO:
--
-- @since 1.0.0
emptyIO :: IO (TMap k v)
emptyIO = atomically empty

-- | TODO:
--
-- @since 1.0.0
singleton :: k -> v -> STM (TMap k v)
singleton k v = do
  cell <- TVar.newTVar v
  tmap <- TVar.newTVar (Map.singleton k cell)
  pure (TMap tmap)

-- | TODO:
--
-- @since 1.0.0
singletonIO :: k -> v -> IO (TMap k v)
singletonIO k v = atomically (singleton k v)

-- -----------------------------------------------------------------------------
--
-- Insertion
--

-- | TODO:
--
-- @since 1.0.0
insert :: Ord k => k -> v -> TMap k v -> STM ()
insert key val (TMap var) = do
  kvs <- TVar.readTVar var
  case Map.lookup key kvs of
    Nothing -> do
      cell <- TVar.newTVar val
      TVar.modifyTVar' var (Map.insert key cell)
    Just cell -> do
      TVar.modifyTVar' var (Map.insert key cell)

-- -----------------------------------------------------------------------------
--
-- Query
--

-- | TODO:
--
-- @since 1.0.0
lookup :: Ord k => k -> TMap k v -> STM (Maybe v)
lookup k (TMap var) = do
  kvs <- TVar.readTVar var
  case Map.lookup k kvs of
    Nothing -> pure Nothing
    Just cell -> Just <$> TVar.readTVar cell

-- -----------------------------------------------------------------------------
--
-- Conversion - Map
--

freeze :: TMap k v -> IO (Map k v)
freeze (TMap var) = atomically do
  kvs <- TVar.readTVar var
  traverse TVar.readTVar kvs

