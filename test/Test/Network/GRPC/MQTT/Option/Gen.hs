module Test.Network.GRPC.MQTT.Option.Gen
  ( protoOptions,
    batched,
    clevel,
  )
where

---------------------------------------------------------------------------------

import Hedgehog (MonadGen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

---------------------------------------------------------------------------------

import Relude

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Option (ProtoOptions)
import Network.GRPC.MQTT.Option qualified as Option
import Network.GRPC.MQTT.Option.Batched (Batched)
import Network.GRPC.MQTT.Option.Batched qualified as Batched
import Network.GRPC.MQTT.Option.CLevel (CLevel)
import Network.GRPC.MQTT.Option.CLevel qualified as CLevel

----------------------------------------------------------------------------------

-- | TODO
protoOptions :: MonadGen m => m ProtoOptions
protoOptions =
  Option.ProtoOptions
    <$> batched
    <*> Gen.maybe clevel
    <*> Gen.maybe clevel

-- | TODO
batched :: MonadGen m => m Batched
batched = Batched.Batch <$> Gen.bool

-- | TODO
clevel :: MonadGen m => m CLevel
clevel = CLevel.CLevel <$> Gen.int (Range.constant 1 22)
