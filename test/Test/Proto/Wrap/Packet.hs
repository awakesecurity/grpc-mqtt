-- | 'Packet' property tests.
module Test.Proto.Wrap.Packet (tests) where

import Hedgehog (Property, forAll, property, withTests, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import Data.Vector qualified as Vector
import GHC.Exts (Proxy#, proxy#)
import Proto3.Suite (Named (nameOf), def)

import Test.Proto.Wrap.Gen qualified as Wrap.Gen
import Test.Proto.Wrap.Property qualified as Wrap.Property

import Network.GRPC.MQTT.Wrap.Packet (Packet (Packet), SeqInfo)

-- -----------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Test.Proto.Wrap.Packet"
    [ testProperty "nameOf @Packet" prop'nameOf
    , testProperty "def @Packet" prop'default
    , wireTests
    ]

-- | prop> nameOf (proxy# :: Proxy# Packet) == "Packet"
prop'nameOf :: Property
prop'nameOf =
  let nm :: String
      nm = nameOf (proxy# :: Proxy# Packet)
   in withTests 1 (property $ nm === "Packet")

-- | prop> def @Packet == Packet (def @SeqInfo) ByteString.empty
prop'default :: Property
prop'default = withTests 1 $ property do
  def === Packet (def @SeqInfo) mempty

-- -----------------------------------------------------------------------------

wireTests :: TestTree
wireTests =
  testGroup
    "Wire Encoding & Decoding"
    [ testProperty "Packet" wire'stream
    ]

-- | Round-trip property test on 'Packet' wire encoding/decoding.
wire'stream :: Property
wire'stream = property do
  ss <- forAll Wrap.Gen.packet
  Wrap.Property.tripWireMessage ss
