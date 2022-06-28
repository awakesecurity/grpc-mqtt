{-# OPTIONS_GHC -Wno-orphans #-}

-- | TODO
--
-- @since 0.1.0.0
module Proto3.Suite.Orphans () where

---------------------------------------------------------------------------------

import Data.Data (Data)
import Data.Ord (Ord)

import Proto3.Suite.DotProto
  ( DotProtoIdentifier (..),
    DotProtoOption (..),
    DotProtoValue (..),
    Path (..),
    RPCMethod (..),
    Streaming (..),
  )

---------------------------------------------------------------------------------

deriving instance Data DotProtoIdentifier
deriving instance Data DotProtoOption
deriving instance Data DotProtoValue
deriving instance Data Path

-- Needed so that 'RPCMethod' can be used to key 'Data.Map.Strict.Map'
deriving instance Ord RPCMethod
deriving instance Ord Streaming
