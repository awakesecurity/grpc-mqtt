{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Network.GRPC.HighLevel.Orphans () where

---------------------------------------------------------------------------------

import Data.Data (Data)
import Data.Ord (Ord)

import Network.GRPC.HighLevel (MetadataMap (MetadataMap))

---------------------------------------------------------------------------------

deriving stock instance Data MetadataMap
deriving newtype instance Ord MetadataMap
