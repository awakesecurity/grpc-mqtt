{-# LANGUAGE ImportQualifiedPost #-}

module Test.Network.GRPC.MQTT.Message.Packet
  ( -- * Test Tree
    tests,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (Property, PropertyT, forAll, property, tripping, (===))
import Hedgehog qualified

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Message.Gen qualified as Message.Gen

--------------------------------------------------------------------------------

import Control.Concurrent.Async (concurrently)

import Control.Concurrent.STM.TQueue (TQueue, writeTQueue, newTQueueIO)

import Relude hiding (reader)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Packet qualified as Packet

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
    [ testTreePacketWire
    , testTreePacketHandle
    ]

-- Packet.Wire -----------------------------------------------------------------

testTreePacketWire :: TestTree
testTreePacketWire =
  testGroup
    "Packet.Wire"
    [ testProperty "Packet.Wire.Client" propPacketWireClient
    , testProperty "Packet.Wire.Remote" propPacketWireRemote
    ]

propPacketWireClient :: Property
propPacketWireClient = property do
  packet <- forAll Message.Gen.packet
  tripping @_ @(Either ParseError)
    packet
    Packet.wireWrapPacket'
    Packet.wireUnwrapPacket

propPacketWireRemote :: Property
propPacketWireRemote = property do
  packet <- forAll Message.Gen.packet
  tripping @_ @(Either ParseError)
    packet
    Packet.wireWrapPacket'
    Packet.wireUnwrapPacket

-- Packet.Handle ---------------------------------------------------------------

testTreePacketHandle :: TestTree
testTreePacketHandle =
  testGroup
    "Packet.Handle"
    [ testProperty "Packet.Handle.ClientToRemote" propHandleClientToRemote
    ]

propHandleClientToRemote :: Property
propHandleClientToRemote = property mockHandlePacket 

mockHandlePacket :: PropertyT IO ()
mockHandlePacket = do
  message <- forAll Message.Gen.packetBytes
  queue <- Hedgehog.evalIO newTQueueIO
  maxsize <- forAll (Message.Gen.packetSplitLength message)

  let reader :: ExceptT ParseError IO ByteString
      reader = Packet.makePacketReader queue

  let sender :: ByteString -> IO ()
      sender = Packet.makePacketSender maxsize (mockPublish queue)

  ((), result) <- Hedgehog.evalIO do
    concurrently (sender message) (runExceptT reader)

  Right message === result

mockPublish :: TQueue ByteString -> ByteString -> IO ()
mockPublish queue message = atomically (writeTQueue queue message)