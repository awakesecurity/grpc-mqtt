-- |
module Test.Response (tests) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import Hedgehog (Property, forAll, property, tripping)
import Hedgehog.Range qualified as Range

import Data.ByteString.Lazy qualified as ByteString.Lazy
import Proto3.Suite.Class qualified as Proto3

import Test.Gen qualified as Gen

--------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Test.Response"
    [ testProperty "instance 'Message' 'Response' round-trip" tripMessageResponse
    ]

tripMessageResponse :: Property
tripMessageResponse = property do
  let range = Range.linear 0 20
  rsp <- forAll (Gen.response range)
  tripping rsp (ByteString.Lazy.toStrict . Proto3.toLazyByteString) Proto3.fromByteString
