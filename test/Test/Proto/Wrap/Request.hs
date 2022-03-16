-- | 'Request' property tests.
module Test.Proto.Wrap.Request (tests) where

import Hedgehog (Property, forAll, property, withTests, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import GHC.Exts (Proxy#, proxy#)
import Proto3.Suite (Named (nameOf), def)

import Test.Proto.Wrap.Gen qualified as Wrap.Gen
import Test.Proto.Wrap.Property qualified as Wrap.Property

import Network.GRPC.MQTT.Wrap.Request (Request (Request))

-- -----------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Test.Proto.Wrap.Request"
    [ testProperty "nameOf @Request" prop'nameOf
    , testProperty "def @Request" prop'default
    , wireTests
    ]

-- | prop> nameOf (proxy# :: Proxy# Request) == "Request"
prop'nameOf :: Property
prop'nameOf =
  let nm :: String
      nm = nameOf (proxy# :: Proxy# Request)
   in withTests 1 (property $ nm === "Request")

-- | prop> def @Request == Stream Vector.empty
prop'default :: Property
prop'default = withTests 1 $ property do
  def === Request 0 mempty mempty

-- -----------------------------------------------------------------------------

wireTests :: TestTree
wireTests =
  testGroup
    "Wire Encoding & Decoding"
    [ testProperty "Request" wire'response
    ]

-- | Round-trip property test on 'Request' wire encoding/decoding.
wire'response :: Property
wire'response = property do
  ss <- forAll Wrap.Gen.response
  Wrap.Property.tripWireMessage ss
