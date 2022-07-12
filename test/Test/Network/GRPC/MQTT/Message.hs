module Test.Network.GRPC.MQTT.Message (tests) where

--------------------------------------------------------------------------------

import Hedgehog ()
import Test.Tasty (TestTree, testGroup)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Message.Packet qualified
import Test.Network.GRPC.MQTT.Message.Request qualified
import Test.Network.GRPC.MQTT.Message.Stream qualified

--------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Message"
    [ Test.Network.GRPC.MQTT.Message.Packet.tests
    , Test.Network.GRPC.MQTT.Message.Request.tests
    , Test.Network.GRPC.MQTT.Message.Stream.tests
    ]
