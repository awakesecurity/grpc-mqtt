{-# OPTIONS_GHC -Wno-orphans #-}
-- | TODO
--
-- @since 0.1.0.0
module Proto3.Suite.Orphans () where

---------------------------------------------------------------------------------

import Data.Data (Data)

import Proto3.Suite.DotProto
  ( DotProtoValue (..),
    DotProtoIdentifier (..),
    Path (..),
  )

---------------------------------------------------------------------------------

deriving instance Data DotProtoValue
deriving instance Data DotProtoIdentifier
deriving instance Data Path
