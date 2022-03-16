-- | 'Stream' property tests.
module Test.Proto.Wrap.Stream (tests) where

import Hedgehog (Property, forAll, property, withTests, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import Data.Vector qualified as Vector
import GHC.Exts (Proxy#, proxy#)
import Proto3.Suite (Named (nameOf), def)

import Test.Proto.Wrap.Gen qualified as Wrap.Gen
import Test.Proto.Wrap.Property qualified as Wrap.Property

import Network.GRPC.MQTT.Wrap.Stream (Stream (Stream))

-- -----------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Test.Proto.Wrap.Stream"
    [ testProperty "nameOf @Stream" prop'nameOf
    , testProperty "def @Stream" prop'default
    , wireTests
    ]

-- | prop> nameOf (proxy# :: Proxy# Stream) == "Stream"
prop'nameOf :: Property
prop'nameOf =
  let nm :: String
      nm = nameOf (proxy# :: Proxy# Stream)
   in withTests 1 (property $ nm === "Stream")

-- | prop> def @Stream == Stream Vector.empty
prop'default :: Property
prop'default = withTests 1 $ property do
  def === Stream Vector.empty

-- -----------------------------------------------------------------------------

wireTests :: TestTree
wireTests =
  testGroup
    "Wire Encoding & Decoding"
    [ testProperty "Stream" wire'stream
    ]

-- | Round-trip property test on 'Stream' wire encoding/decoding.
wire'stream :: Property
wire'stream = property do
  ss <- forAll Wrap.Gen.stream
  Wrap.Property.tripWireMessage ss
