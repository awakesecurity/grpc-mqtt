{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Network.GRPC.HighLevel.Orphans () where

---------------------------------------------------------------------------------

import Data.Data (Data)

import Network.GRPC.HighLevel (MetadataMap (MetadataMap))
import Network.GRPC.HighLevel.Client (ClientResult (..))

import Relude

---------------------------------------------------------------------------------

deriving stock instance Functor (ClientResult s)

deriving stock instance Data MetadataMap
deriving newtype instance Ord MetadataMap
