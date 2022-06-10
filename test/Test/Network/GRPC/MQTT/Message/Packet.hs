{-# LANGUAGE ImportQualifiedPost #-}

module Test.Network.GRPC.MQTT.Message.Packet
  ( -- * Test Tree
    tests,
  )
where

---------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property, tripping, (===))
import Hedgehog qualified as Hedgehog
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

---------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Message.Packet.Gen qualified as Gen

---------------------------------------------------------------------------------

import Control.Concurrent.STM.TChan (newTChanIO, writeTChan)

import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as Lazy (ByteString)
import Data.ByteString.Lazy qualified as LByteString
import Data.Vector (Vector)
import Data.Vector qualified as Vector

import Proto3.Wire.Decode qualified as Decode

import Relude

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Packet (Packet)
import Network.GRPC.MQTT.Message.Packet qualified as Packet

----------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Message.Packet"
    [ testProperty "propPacketOrdering" propPacketOrdering
    , testProperty "propEmptySplitPackets" propEmptySplitPackets
    , testProperty "propMergeSplitPackets" propMergeSplitPackets
    , testProperty "Wire.Packet" tripWireFormatPacket
    ]

-- | Round-trip test on 'Packet' serialization.
tripWireFormatPacket :: Property
tripWireFormatPacket = property do
  payload <- forAll Gen.packet
  tripping payload to from
  where
    to :: Packet ByteString -> LByteString
    to = Packet.wireWrapPacket

    from :: LByteString -> Either Decode.ParseError (Packet ByteString)
    from = Packet.wireUnwrapPacket . toStrict

propPacketOrdering :: Property
propPacketOrdering = property do
  -- Generates a packetized 'ByteString' @pxs@, along with a random permutation
  -- of those packets @pys@.
  pxs <- forAll Gen.packetVector
  pys <- forAll (Gen.shufflePackets pxs)

  -- Writes each encoded packet from the shuffled vector of packets to the
  -- channel. This is to simulate recieving packet out of the order in they are
  -- needed.
  result <- Hedgehog.evalIO do
    channel <- newTChanIO
    for_ pys \packet -> atomically do
      writeTChan channel (Packet.wireWrapPacket packet)
    runExceptT (Packet.packetReader channel)

  -- If 'Packet.packetReader' is able to correctly order packets it recieves,
  -- then @result@ should be equal to the unshuffled vector of packets.
  let expect :: LByteString
      expect = fromStrict (foldMap Packet.payload pxs)
   in Right expect === result

-- | Splitting an empty 'ByteString' into packets yields a singleton vector
-- containing a packet with an empty payload.
propEmptySplitPackets :: Property
propEmptySplitPackets = property do
  maxsize <- forAll (Gen.int Range.constantBounded)
  let packets :: Vector (Packet ByteString)
      packets = Packet.splitPackets maxsize ByteString.empty
   in packets === Vector.singleton (Packet.fromByteString ByteString.empty)

-- | Splitting a 'ByteString' into a vector of 'Packet' can be reversed by
-- concatenating the payload's of each packet.
propMergeSplitPackets :: Property
propMergeSplitPackets = property do
  message <- forAll Gen.packetBytes
  maxsize <- forAll (Gen.packetSplitLength message)
  let packets :: Vector (Packet ByteString)
      packets = Packet.splitPackets maxsize message
   in message === foldMap Packet.payload packets
