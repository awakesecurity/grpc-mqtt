{-# LANGUAGE ImportQualifiedPost #-}

module Test.Network.GRPC.MQTT.Message.Request
  ( -- * Test Tree
    tests,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property, tripping, (===))
import Hedgehog qualified as Hedgehog

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Message.Gen qualified as Message.Gen

--------------------------------------------------------------------------------

import Control.Concurrent.Async (concurrently)

import Control.Concurrent.STM.TChan (TChan, newTChanIO, writeTChan)

import Relude hiding (reader)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message (Request, WireDecodeError)
import Network.GRPC.MQTT.Message.Request qualified as Request

import Proto3.Wire.Decode qualified as Decode

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
  channel <- Hedgehog.evalIO newTChanIO
  request <- forAll Message.Gen.request
  maxsize <- forAll (Message.Gen.packetSplitLength (Request.message request))

  let reader :: ExceptT WireDecodeError IO (Request ByteString)
      reader = Request.makeRequestReader channel

  let sender :: Request ByteString -> IO ()
      sender = Request.makeRequestSender maxsize (mockPublish channel)

  ((), result) <- Hedgehog.evalIO do
    concurrently (sender request) (runExceptT reader)

  Right request === result

--------------------------------------------------------------------------------

mockPublish :: TChan LByteString -> ByteString -> IO ()
mockPublish channel message =
  let message' :: LByteString
      message' = fromStrict @LByteString @ByteString message
   in atomically (writeTChan channel message')