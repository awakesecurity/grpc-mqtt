-- | This module exports useful 'Hedgehog' generators.
module Test.Gen
  ( -- * Generators
    -- response,
    -- metadataMap,
  )
where

import Test.Tasty
import Test.Tasty.Hedgehog

import Hedgehog
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

import Control.Applicative (liftA2)
import Network.GRPC.HighLevel (MetadataMap (MetadataMap))

-- import Network.GRPC.MQTT.Response

--------------------------------------------------------------------------------

-- response :: MonadGen m => Range Int -> m Response
-- response range =
--   Response
--     <$> Gen.bytes range
--     <*> metadataMap range
--     <*> metadataMap range
--     <*> Gen.int32 Range.constantBounded
--     <*> Gen.list range Gen.unicode

-- metadataMap :: MonadGen m => Range Int -> m MetadataMap
-- metadataMap range = do
--   ms <- Gen.map range do
--     k <- Gen.bytes range
--     v <- Gen.list range (Gen.bytes range)
--     pure (k, v)
--   pure (MetadataMap ms)
