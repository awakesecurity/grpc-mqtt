{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      :  Network.GRPC.HighLevel.Orphans
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see LICENSE
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
module Network.GRPC.HighLevel.Orphans () where

---------------------------------------------------------------------------------

import Network.GRPC.HighLevel.Client (ClientResult (..))

import Relude

---------------------------------------------------------------------------------

deriving stock instance Functor (ClientResult s)
