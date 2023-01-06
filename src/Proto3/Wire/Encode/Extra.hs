-- |
-- Module      :  Proto3.Wire.Encode.Extra
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see LICENSE
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- Extensions to the proto-wire format encoders missing from the proto3-wire
-- package.
--
-- @since 1.0.0
module Proto3.Wire.Encode.Extra
  ( -- * Primitive Message Builders
    sint,
  )
where

---------------------------------------------------------------------------------

import Proto3.Wire (FieldNumber)
import Proto3.Wire.Encode (MessageBuilder)
import Proto3.Wire.Encode qualified as Encode

import Relude

-- Primitive Message Builders ---------------------------------------------------

-- | Serializes a 'Int' primitive as a fixed-width 64-bit integer.
--
-- @since 1.0.0
sint :: FieldNumber -> Int -> MessageBuilder
sint field int = do
  let int64 :: Int64
      int64 = fromIntegral int
   in Encode.sint64 field int64
