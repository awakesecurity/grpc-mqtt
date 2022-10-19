{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Network.GRPC.HighLevel.Orphans () where

---------------------------------------------------------------------------------

import Network.GRPC.HighLevel.Client (ClientResult (..))

import Relude

---------------------------------------------------------------------------------

deriving stock instance Functor (ClientResult s)
