module Test.Network.GRPC.MQTT
  ( -- * Test Tree
    tests,
  )
where

--------------------------------------------------------------------------------

import Test.Tasty (TestTree, testGroup)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Compress qualified
import Test.Network.GRPC.MQTT.Message qualified
import Test.Network.GRPC.MQTT.Option qualified
import Test.Network.GRPC.MQTT.Serial qualified
import Test.Network.GRPC.MQTT.OrderedTQueue qualified

-- Network.GRPC.MQTT -----------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT"
    [ Test.Network.GRPC.MQTT.Compress.tests
    , Test.Network.GRPC.MQTT.Message.tests
    , Test.Network.GRPC.MQTT.Option.tests
    , Test.Network.GRPC.MQTT.Serial.tests
    , Test.Network.GRPC.MQTT.OrderedTQueue.tests
    ]