{-# LANGUAGE ImportQualifiedPost #-}

module Test.Network.GRPC.MQTT.Message.Request
  ( -- * Test Tree
    tests,
  )
where

import Control.Concurrent.STM.TQueue (newTQueueIO)

import Hedgehog (Property, forAll, property, tripping, (===))
import Hedgehog qualified as Hedgehog

import Network.GRPC.MQTT.Message (Request, WireDecodeError)
import Network.GRPC.MQTT.Message.Request qualified as Request

import Proto3.Wire.Decode qualified as Decode

import Test.Core (mockPublish)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import Test.Network.GRPC.MQTT.Message.Gen qualified as Message.Gen

import Relude hiding (reader)

--------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Message.Request"
    [ testProperty "Request.Wire" propRequestWire
    , testProperty "Request.Handle" propRequestHandle
    ]

--------------------------------------------------------------------------------

propRequestWire :: Property
propRequestWire = property do
  request <- forAll Message.Gen.request
  tripping
    request
    Request.wireWrapRequest'
    (Request.wireUnwrapRequest @(Either Decode.ParseError))

propRequestHandle :: Property
propRequestHandle = property do
  queue <- Hedgehog.evalIO newTQueueIO
  request <- forAll Message.Gen.request
  maxsize <- forAll (Message.Gen.packetSplitLength (Request.message request))

  let reader :: ExceptT WireDecodeError IO (Request ByteString)
      reader = Request.makeRequestReader queue

  let sender :: Request ByteString -> IO ()
      sender = Request.makeRequestSender maxsize (mockPublish queue)

  result <- Hedgehog.evalIO do
    sender request
    runExceptT reader

  Right request === result