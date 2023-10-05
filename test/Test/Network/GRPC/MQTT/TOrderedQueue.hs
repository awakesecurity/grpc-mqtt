module Test.Network.GRPC.MQTT.TOrderedQueue
  ( -- * Test Tree
    tests,
  )
where

import Relude

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
import Hedgehog (Property, forAll, property, (===))
import Hedgehog qualified

import Control.Concurrent.TOrderedQueue
  ( SequenceId (SequenceId, Unordered),
    Sequenced (Sequenced),
    newTOrderedQueueIO,
    readTOrderedQueue,
    val,
    writeTOrderedQueue,
  )
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.TOrderedQueue"
    [ testProperty "Order" orderMaintained
    , testProperty "Unordered" unorderedRespected
    ]

orderMaintained :: Property
orderMaintained = property do
  queue <- Hedgehog.evalIO newTOrderedQueueIO

  n <- forAll $ Gen.int (Range.linear 0 1_000)

  let messages :: [Sequenced Int]
      messages = zipWith Sequenced (SequenceId <$> [0 ..]) [0 .. n]

  shuffledMessages <- forAll $ Gen.shuffle messages

  atomically $ traverse_ (writeTOrderedQueue queue) shuffledMessages

  receivedMessages <- atomically $ replicateM (length shuffledMessages) (readTOrderedQueue queue)

  receivedMessages === (val <$> messages)

unorderedRespected :: Property
unorderedRespected = property do
  queue <- Hedgehog.evalIO newTOrderedQueueIO

  n <- forAll $ Gen.int (Range.linear 0 1_000)

  let messages :: [Sequenced Int]
      messages = zipWith Sequenced (SequenceId <$> [0 ..]) [0 .. n]

  let unorderedMsgs = fmap (Sequenced Unordered) [0 .. n]

  shuffledMessages <- forAll $ Gen.shuffle messages

  let interlacedShuffledMessages = interlace shuffledMessages unorderedMsgs

  atomically $ traverse_ (writeTOrderedQueue queue) interlacedShuffledMessages

  receivedMessages <- atomically $ replicateM (length interlacedShuffledMessages) (readTOrderedQueue queue)

  -- All unordered should be pushed to the front but still be in FIFO order
  receivedMessages === fmap val (unorderedMsgs ++ messages)
  where
    interlace [] ys = ys
    interlace xs [] = xs
    interlace (x : xs) (y : ys) = x : y : interlace xs ys
