{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | Extensions to the proto-wire format encoders missing from the proto3-wire
-- package.
--
-- @since 0.1.0.0
module Proto3.Wire.Encode.Extra
  ( -- * Primitive Message Builders
    sint,
  )
where

---------------------------------------------------------------------------------

import Data.Int (Int64)

import Proto3.Wire (FieldNumber)
import Proto3.Wire.Encode (MessageBuilder)
import Proto3.Wire.Encode qualified as Encode

-- Primitive Message Builders ---------------------------------------------------

-- | Serializes a 'Int' primitive as a fixed-width 64-bit integer.
--
-- @since 0.1.0.0
sint :: FieldNumber -> Int -> MessageBuilder
sint field int = do
  let int64 :: Int64
      int64 = fromIntegral int
   in Encode.sint64 field int64
