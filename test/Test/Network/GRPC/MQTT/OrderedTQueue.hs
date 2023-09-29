module Test.Network.GRPC.MQTT.OrderedTQueue
  ( -- * Test Tree
    tests,
  )
where

import Relude

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
import Hedgehog (Property, forAll, property, (===))
import Hedgehog qualified

import Control.Concurrent.OrderedTQueue
  ( Indexed (Indexed),
    newOrderedTQueueIO,
    readOrderedTQueue,
    writeOrderedTQueue,
  )
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.OrderedTQueue"
    [ testProperty "Order" orderMaintained
    ]

orderMaintained :: Property
orderMaintained = property do
  queue <- Hedgehog.evalIO newOrderedTQueueIO

  n <- forAll $ Gen.int32 (Range.linear 0 1_000)

  let messages :: [Indexed Int]
      messages = zipWith Indexed [0 .. n] [0 ..]

  shuffledMessages <- forAll $ Gen.shuffle messages

  atomically $ traverse_ (writeOrderedTQueue queue) shuffledMessages

  receivedMessages <- atomically $ replicateM (fromIntegral n + 1) (readOrderedTQueue queue)

  receivedMessages === [x | Indexed _ x <- messages]
