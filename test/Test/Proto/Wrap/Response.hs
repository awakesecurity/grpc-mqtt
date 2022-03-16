-- | 'Response' property tests.
module Test.Proto.Wrap.Response (tests) where

import Hedgehog (Property, forAll, property, withTests, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import GHC.Exts (Proxy#, proxy#)
import Proto3.Suite (Named (nameOf), def)

import Test.Proto.Wrap.Gen qualified as Wrap.Gen
import Test.Proto.Wrap.Property qualified as Wrap.Property

import Network.GRPC.MQTT.Wrap.Response (Response (Response))

-- -----------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Test.Proto.Wrap.Response"
    [ testProperty "nameOf @Response" prop'nameOf
    , testProperty "def @Response" prop'default
    , wireTests
    ]

-- | prop> nameOf (proxy# :: Proxy# Response) == "Response"
prop'nameOf :: Property
prop'nameOf =
  let nm :: String
      nm = nameOf (proxy# :: Proxy# Response)
   in withTests 1 (property $ nm === "Response")

-- | prop> def @Response == Stream Vector.empty
prop'default :: Property
prop'default = withTests 1 $ property do
  def === Response mempty mempty mempty 2 mempty

-- -----------------------------------------------------------------------------

wireTests :: TestTree
wireTests =
  testGroup
    "Wire Encoding & Decoding"
    [ testProperty "Response" wire'response
    ]

-- | Round-trip property test on 'Response' wire encoding/decoding.
wire'response :: Property
wire'response = property do
  ss <- forAll Wrap.Gen.response
  Wrap.Property.tripWireMessage ss
