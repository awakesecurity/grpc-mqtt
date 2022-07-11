{-# LANGUAGE ImportQualifiedPost #-}

module Test.Network.GRPC.MQTT.Message.Stream
  ( -- * Test Tree
    tests,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Message.Gen qualified as Message.Gen

import Test.Suite.Wire qualified as Test.Wire

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Stream qualified as Stream

--------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Message.Stream"
    [ testTreeStreamWire
    ]

-- Stream.Wire -----------------------------------------------------------------

testTreeStreamWire :: TestTree
testTreeStreamWire =
  testGroup
    "Packet.Wire"
    [ testProperty "Stream.Wire.Client" propPacketWireClient
    , testProperty "Stream.Wire.Remote" propPacketWireRemote
    ]

propPacketWireClient :: Property
propPacketWireClient = property do
  chunk <- forAll Message.Gen.streamChunk
  Test.Wire.testWireClientRoundtrip
    chunk
    Stream.wireEncodeStreamChunk
    Stream.wireUnwrapStreamChunk

propPacketWireRemote :: Property
propPacketWireRemote = property do
  chunk <- forAll Message.Gen.streamChunk
  Test.Wire.testWireRemoteRoundtrip
    chunk
    Stream.wireEncodeStreamChunk
    Stream.wireUnwrapStreamChunk

-- Packet.Handle ---------------------------------------------------------------