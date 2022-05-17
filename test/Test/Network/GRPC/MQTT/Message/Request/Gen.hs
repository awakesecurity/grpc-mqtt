{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | Generators for 'Request' messages.
module Test.Network.GRPC.MQTT.Message.Request.Gen
  ( -- * Generators
    request,
    requestMessage,
    requestTimeout,
  )
where

---------------------------------------------------------------------------------

import Hedgehog (MonadGen, Range)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

---------------------------------------------------------------------------------

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
  message <- requestMessage
  timeout <- requestTimeout
  metadata <- Gen.metadataMap
  pure (Request message timeout metadata)

-- | Generates possibly empty 'ByteString' with a length bounded by the size
-- parameter.
--
-- Used to emulate a serialized protobuf message embedded in a 'Request'.
requestMessage :: MonadGen m => m ByteString
requestMessage = do
  Gen.sized \size -> do
    upper <- Gen.int (Range.constant 0 (fromIntegral size))
    let range :: Range Int
        range = Range.constant 0 upper
     in Gen.bytes range

-- | Generates a request timeout in seconds, bounded [0, maxBound @Int].
requestTimeout :: MonadGen m => m Int
requestTimeout =
  let range :: Range Int
      range = Range.constant 0 maxBound
   in Gen.int range
