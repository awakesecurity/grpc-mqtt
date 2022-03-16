-- | Hedgehog property testing combinators for use in the @Test.Proto.Wrap@
-- module group.
module Test.Proto.Wrap.Property
  ( -- * Property Combinators
    tripWireMessage,
  )
where

import Hedgehog (MonadTest, tripping)

import Data.ByteString.Lazy qualified as Lazy (ByteString)
import Data.ByteString.Lazy qualified as Lazy.ByteString

-- proto3-suite -----

import Proto3.Suite qualified
import Proto3.Suite.Class (Message)
import Proto3.Wire.Decode (ParseError)

-- -----------------------------------------------------------------------------

tripWireMessage :: (MonadTest m, Message a, Eq a, Show a) => a -> m ()
tripWireMessage msg =
  tripping msg (Lazy.ByteString.toStrict . encoding) decoding
  where
    encoding :: Message a => a -> Lazy.ByteString
    encoding = Proto3.Suite.toLazyByteString

    decoding :: Message a => ByteString -> Either ParseError a
    decoding = Proto3.Suite.fromByteString
