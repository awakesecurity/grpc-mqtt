{-# LANGUAGE ImportQualifiedPost #-}

module Test.Network.GRPC.MQTT.Message.Packet
  ( -- * Test Tree
    tests,
  )
where

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property, tripping, (===))
import Hedgehog qualified

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Message.Gen qualified as Message.Gen

--------------------------------------------------------------------------------

import Control.Concurrent.Async (concurrently)

import Control.Concurrent.STM.TQueue
  ( TQueue,
    flushTQueue,
    newTQueueIO,
    writeTQueue,
  )

import Relude hiding (reader)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Packet qualified as Packet

import Data.ByteString qualified as ByteString
import Proto3.Wire.Decode (ParseError)

--------------------------------------------------------------------------------

data TestLabels
  = PacketClientCompress
  | PacketRemoteCompress
  deriving (Show)

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Message.Packet"
    [ testProperty "Packet.Wire" propPacketWire
    , testProperty "Packet.Handle" propPacketHandle
    , testProperty "Packet.MaxSize" propPacketMaxSize
    ]

propPacketWire :: Property
propPacketWire = property do
  packet <- forAll Message.Gen.packet
  tripping @_ @(Either ParseError)
    packet
    Packet.wireWrapPacket'
    Packet.wireUnwrapPacket

propPacketHandle :: Property
propPacketHandle = property do
  message <- forAll Message.Gen.packetBytes
  maxsize <- forAll (Message.Gen.packetSplitLength message)
  queue <- Hedgehog.evalIO newTQueueIO

  let reader :: ExceptT ParseError IO ByteString
      reader = Packet.makePacketReader queue

  let sender :: ByteString -> IO ()
      sender = Packet.makePacketSender maxsize Nothing (mockPublish queue)

  ((), result) <- Hedgehog.evalIO do
    concurrently (sender message) (runExceptT reader)

  Right message === result

mockPublish :: TQueue ByteString -> ByteString -> IO ()
mockPublish queue message = atomically (writeTQueue queue message)

propPacketMaxSize :: Property
propPacketMaxSize = property do
  message <- forAll Message.Gen.packetBytes
  maxsize <- forAll (Message.Gen.packetSplitLength message)
  queue <- Hedgehog.evalIO newTQueueIO

  let sender :: ByteString -> IO ()
      sender = Packet.makePacketSender maxsize Nothing (atomically . writeTQueue queue)

  packets <- Hedgehog.evalIO do
    sender message
    atomically (flushTQueue queue)

  for_ packets \packet ->
    let size :: Word32
        size = fromIntegral (ByteString.length packet)
     in Hedgehog.assert (size <= maxsize)