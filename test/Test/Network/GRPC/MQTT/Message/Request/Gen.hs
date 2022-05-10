{-# LANGUAGE ImplicitPrelude #-}

-- |
--
--
module Test.Network.GRPC.MQTT.Message.Request.Gen
  ( -- * Generators
    request,
    payload
  )
where

---------------------------------------------------------------------------------

import Hedgehog (MonadGen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range


import Test.Network.GRPC.HighLevel.Extra.Gen qualified as Gen

---------------------------------------------------------------------------------

import Data.ByteString (ByteString)

import Network.GRPC.MQTT.Message.Request (Request (Request))

---------------------------------------------------------------------------------
--
-- Generators
--

-- | Generates an MQTT 'Request' wrapper with a random 'ByteString' as the
-- request body.
request :: MonadGen m => m (Request ByteString)
request = do
  xs <- payload
  to <- Gen.int Range.constantBounded
  ms <- Gen.metadataMap
  pure (Request xs to ms)

-- | Generates 'ByteString' with a length bounded by the size parameter. The
-- 'payload' generator can be used to emulate a wire-encoded message body.
--
payload :: MonadGen m => m ByteString
payload = do
  high <- Gen.sized (pure . fromIntegral)
  size <- Gen.int (Range.linear 0 high)
  Gen.bytes (Range.linear 0 size)
