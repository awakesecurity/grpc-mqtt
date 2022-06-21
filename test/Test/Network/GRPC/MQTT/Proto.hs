module Test.Network.GRPC.MQTT.Proto (tests) where

---------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property, tripping, (===))
import Hedgehog qualified as Hedgehog
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

---------------------------------------------------------------------------------

---------------------------------------------------------------------------------

import Relude

---------------------------------------------------------------------------------


----------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    ""
    [
    ]
