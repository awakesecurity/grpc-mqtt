{-# LANGUAGE ImportQualifiedPost #-}

module Test.Network.GRPC.MQTT.Message.Packet
  ( -- * Test Tree
    tests,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (Property, PropertyT, forAll, property, tripping, (===))
import Hedgehog qualified
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Message.Gen qualified as Message.Gen
import Test.Network.GRPC.MQTT.Option.Gen qualified as Option.Gen

import Test.Suite.Wire qualified as Test.Wire

--------------------------------------------------------------------------------

import Control.Concurrent.Async (concurrently)

import Control.Concurrent.STM.TQueue (TQueue, writeTQueue, newTQueueIO)

import Data.ByteString qualified as ByteString
import Data.Vector (Vector)
import Data.Vector qualified as Vector

import Proto3.Suite qualified as Proto3

import Relude hiding (reader)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message (Packet, WireDecodeError)
import Network.GRPC.MQTT.Message.Packet qualified as Packet

import Network.GRPC.MQTT.Serial (WireDecodeOptions, WireEncodeOptions)
import Network.GRPC.MQTT.Serial qualified as Serial

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
    , testTreePacketSplit
    , testTreePacketOrder
    , testTreePacketHandle
    , testTreePacketInfo
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
  Test.Wire.testWireClientRoundtrip
    packet
    Packet.wireWrapPacket'
    Packet.wireUnwrapPacket

propPacketWireRemote :: Property
propPacketWireRemote = property do
  packet <- forAll Message.Gen.packet
  Test.Wire.testWireRemoteRoundtrip
    packet
    Packet.wireWrapPacket'
    Packet.wireUnwrapPacket

-- Packet.Split ----------------------------------------------------------------

testTreePacketSplit :: TestTree
testTreePacketSplit =
  testGroup
    "Packet.Split"
    [ testProperty "Packet.Split.Empty" propPacketSplitEmpty
    , testProperty "Packet.Split.Merge" propPacketSplitMerge
    ]

-- | Splitting an empty 'ByteString' into packets yields a singleton vector
-- containing a packet with an empty payload.
propPacketSplitEmpty :: Property
propPacketSplitEmpty = property do
  maxsize <- forAll (Gen.int Range.constantBounded)
  let packets :: Vector (Packet ByteString)
      packets = Packet.splitPackets maxsize ByteString.empty
   in packets === Vector.singleton (Packet.Packet ByteString.empty (Packet.PacketInfo 0 1))

-- | Splitting a 'ByteString' into a vector of 'Packet' can be reversed by
-- concatenating the payload's of each packet.
propPacketSplitMerge :: Property
propPacketSplitMerge = property do
  message <- forAll Message.Gen.packetBytes
  maxsize <- forAll (Message.Gen.packetSplitLength message)
  let packets :: Vector (Packet ByteString)
      packets = Packet.splitPackets maxsize message
   in message === foldMap Packet.payload packets

-- Packet.Order ----------------------------------------------------------------

testTreePacketOrder :: TestTree
testTreePacketOrder =
  testGroup
    "Packet.Order"
    [ testProperty "Packet.Order.Client" propPacketOrderClient
    , testProperty "Packet.Order.Remote" propPacketOrderRemote
    ]

propPacketOrderClient :: Property
propPacketOrderClient = property do
  options <- forAll Option.Gen.protoOptions
  mockPacketShuffle
    (Serial.makeClientEncodeOptions options)
    (Serial.makeClientDecodeOptions options)

propPacketOrderRemote :: Property
propPacketOrderRemote = property do
  options <- forAll Option.Gen.protoOptions
  mockPacketShuffle
    (Serial.makeRemoteEncodeOptions options)
    (Serial.makeRemoteDecodeOptions options)

-- Packet.Handle ---------------------------------------------------------------

testTreePacketHandle :: TestTree
testTreePacketHandle =
  testGroup
    "Packet.Handle"
    [ testProperty "Packet.Handle.ClientToRemote" propHandleClientToRemote
    , testProperty "Packet.Handle.RemoteToClient" propHandleRemoteToClient
    ]

propHandleClientToRemote :: Property
propHandleClientToRemote = property do
  options <- forAll Option.Gen.protoOptions
  mockHandlePacket
    (Serial.makeClientEncodeOptions options)
    (Serial.makeClientDecodeOptions options)

propHandleRemoteToClient :: Property
propHandleRemoteToClient = property do
  options <- forAll Option.Gen.protoOptions
  mockHandlePacket
    (Serial.makeRemoteEncodeOptions options)
    (Serial.makeRemoteDecodeOptions options)

-- Packet.PacketInfo.Wire ------------------------------------------------------

testTreePacketInfo :: TestTree
testTreePacketInfo =
  testGroup
    "Packet.PacketInfo"
    [ testProperty "Packet.PacketInfo.Wire" propPacketInfoWire
    ]

propPacketInfoWire :: Property
propPacketInfoWire = property do
  info <- forAll Message.Gen.packetInfo
  tripping info (toStrict . Proto3.toLazyByteString) Proto3.fromByteString

--------------------------------------------------------------------------------

mockPacketShuffle :: WireEncodeOptions -> WireDecodeOptions -> PropertyT IO ()
mockPacketShuffle encodeOptions decodeOptions = do
  -- Generates a packetized 'ByteString' @pxs@, along with a random permutation
  -- of those packets @pys@.
  pxs <- forAll Message.Gen.packetVector
  pys <- forAll (Message.Gen.shufflePackets pxs)

  -- Writes each encoded packet from the shuffled vector of packets to the
  -- channel. This is to simulate recieving packet out of the order in they are
  -- needed.
  result <- Hedgehog.evalIO do
    queue <- newTQueueIO
    for_ pys \packet -> atomically do
      writeTQueue queue (Packet.wireWrapPacket' encodeOptions packet)
    runExceptT (Packet.makePacketReader queue decodeOptions)

  -- If 'Packet.packetReader' is able to correctly order packets it recieves,
  -- then @result@ should be equal to the unshuffled vector of packets.
  Right (foldMap Packet.payload pxs) === result

mockHandlePacket :: WireEncodeOptions -> WireDecodeOptions -> PropertyT IO ()
mockHandlePacket encodeOptions decodeOptions = do
  message <- forAll Message.Gen.packetBytes
  queue <- Hedgehog.evalIO newTQueueIO
  maxsize <- forAll (Message.Gen.packetSplitLength message)

  let reader :: ExceptT WireDecodeError IO ByteString
      reader = Packet.makePacketReader queue decodeOptions

  let sender :: ByteString -> IO ()
      sender = Packet.makePacketSender maxsize encodeOptions (mockPublish queue)

  ((), result) <- Hedgehog.evalIO do
    concurrently (sender message) (runExceptT reader)

  Right message === result

mockPublish :: TQueue ByteString -> ByteString -> IO ()
mockPublish queue message = atomically (writeTQueue queue message)