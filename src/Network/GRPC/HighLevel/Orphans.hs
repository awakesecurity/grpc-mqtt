{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Module declaring instances for types exported by the grpc-haskell package.
--
-- @since 1.0.0
module Network.GRPC.HighLevel.Orphans () where

---------------------------------------------------------------------------------

import Data.Data (Data)

import Network.GRPC.HighLevel (MetadataMap (MetadataMap))

---------------------------------------------------------------------------------

deriving stock instance Data MetadataMap
deriving newtype instance Ord MetadataMap
