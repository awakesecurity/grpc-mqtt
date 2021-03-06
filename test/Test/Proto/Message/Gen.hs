{-# LANGUAGE ImportQualifiedPost #-}

-- | Hedgehog generators for the Haskell type generated from
-- @test/proto/message.proto@ message.
module Test.Proto.Message.Gen
  ( -- * Message Generators
    oneInt,
    twoInts,
    streamRequest,
    streamReply,
    bidiRequestReply,

    -- * Generators
    size'list
  )
where

--------------------------------------------------------------------------------

import Hedgehog (MonadGen, Range)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

--------------------------------------------------------------------------------

import Relude

--------------------------------------------------------------------------------

import Proto.Message (BiDiRequestReply, OneInt, StreamReply, StreamRequest, TwoInts)
import Proto.Message qualified as Message

--------------------------------------------------------------------------------

oneInt :: MonadGen m => m OneInt
oneInt = fmap Message.OneInt size'int32

twoInts :: MonadGen m => m TwoInts
twoInts = do
  -- The upper and lower ranges are limit to half of the maximum and minimum
  -- bounds for @Int32@ so that the contents of the generated @Int32@ can safely
  -- be added and subtracted without overflow.
  let range :: Range Int32
      range = Range.constant (quot minBound 2 + 1) (quot maxBound 2)
   in liftA2 Message.TwoInts (Gen.int32 range) (Gen.int32 range)

streamRequest :: MonadGen m => m StreamRequest
streamRequest = liftA2 Message.StreamRequest lazy'text size'word32

streamReply :: MonadGen m => m StreamReply
streamReply = fmap Message.StreamReply lazy'text

bidiRequestReply :: MonadGen m => m BiDiRequestReply
bidiRequestReply = fmap Message.BiDiRequestReply lazy'text

--------------------------------------------------------------------------------

size'list :: MonadGen m => m a -> m [a]
size'list gen =
  Gen.sized \s -> do
    let range :: Range Int
        range = Range.constant 1 (fromIntegral s)
     in Gen.list range gen

lazy'text :: MonadGen m => m LText
lazy'text =
  Gen.sized \s -> do
    high <- Gen.int (Range.constant 1 (fromIntegral s))
    text <- Gen.string (Range.constant 1 (1 + high)) Gen.alpha
    pure (toLText text)

size'int32 :: MonadGen m => m Int32
size'int32 =
  Gen.sized \s ->
    let range :: Range Int32
        range = Range.constant 1 (1 + fromIntegral s)
     in Gen.int32 range

size'word32 :: MonadGen m => m Word32
size'word32 =
  Gen.sized \s ->
    let range :: Range Word32
        range = Range.constant 1 (1 + fromIntegral s)
     in Gen.word32 range
