module Test.Network.GRPC.MQTT.Serial
  ( -- * Test Tree
    tests,

    -- * Test Labels
    SerialTestLabel (SerialZstdEnable),

    -- * Test Combinators
    diffWireOptions,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (Property, PropertyT, forAll, property, withTests)
import Hedgehog qualified as Hedgehog

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Option.Gen qualified as Option.Gen

--------------------------------------------------------------------------------

import Relude hiding (reader)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Option qualified as Option

import Network.GRPC.MQTT.Serial (WireDecodeOptions, WireEncodeOptions)
import Network.GRPC.MQTT.Serial qualified as Serial

-- Serial ----------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Serial"
    [ testTreeDefault
    , testTreeDiff
    ]

-- Serial.Default --------------------------------------------------------------

-- | Properties testing the client and remote serialization options obtained
-- from the default 'Option.defaultProtoOptions' value agree with the default
-- 'Serial.defaultEncodeOptions' and 'Serial.defaultDecodeOptions' value.
testTreeDefault :: TestTree
testTreeDefault =
  testGroup
    "Serial.Default"
    [ testGroup
        "Serial.Default.Client"
        [ testProperty "Serial.Default.Client.Encode" testDefaultClientEncode
        , testProperty "Serial.Default.Client.Decode" testDefaultClientDecode
        ]
    , testGroup
        "Serial.Default.Remote"
        [ testProperty "Serial.Default.Remote.Encode" testDefaultRemoteEncode
        , testProperty "Serial.Default.Remote.Decode" testDefaultRemoteDecode
        ]
    ]

testDefaultClientEncode :: Property
testDefaultClientEncode = withTests 1 $ property do
  let encodeOptions :: WireEncodeOptions
      encodeOptions = Serial.makeClientEncodeOptions Option.defaultProtoOptions
   in Hedgehog.diff Serial.defaultEncodeOptions (==) encodeOptions

testDefaultClientDecode :: Property
testDefaultClientDecode = withTests 1 $ property do
  let decodeOptions :: WireDecodeOptions
      decodeOptions = Serial.makeClientDecodeOptions Option.defaultProtoOptions
   in Hedgehog.diff Serial.defaultDecodeOptions (==) decodeOptions

testDefaultRemoteEncode :: Property
testDefaultRemoteEncode = withTests 1 $ property do
  let encodeOptions :: WireEncodeOptions
      encodeOptions = Serial.makeRemoteEncodeOptions Option.defaultProtoOptions
   in Hedgehog.diff Serial.defaultEncodeOptions (==) encodeOptions

testDefaultRemoteDecode :: Property
testDefaultRemoteDecode = withTests 1 $ property do
  let decodeOptions :: WireDecodeOptions
      decodeOptions = Serial.makeRemoteDecodeOptions Option.defaultProtoOptions
   in Hedgehog.diff Serial.defaultDecodeOptions (==) decodeOptions

-- Serial.Default --------------------------------------------------------------

-- | Properties testing that the 'WireEncodeOption' and 'WireDecodeOption'
-- values obtained from a 'ProtoOption' value agree with eachother.
testTreeDiff :: TestTree
testTreeDiff =
  testGroup
    "Serial.Diff"
    [ testProperty "Serial.Diff.Client" testDiffClient
    , testProperty "Serial.Diff.Remote" testDiffRemote
    ]

testDiffRemote :: Property
testDiffRemote = property do
  options <- forAll Option.Gen.protoOptions
  diffWireOptions
    (Serial.makeClientEncodeOptions options)
    (Serial.makeClientDecodeOptions options)

testDiffClient :: Property
testDiffClient = property do
  options <- forAll Option.Gen.protoOptions
  diffWireOptions
    (Serial.makeRemoteEncodeOptions options)
    (Serial.makeRemoteDecodeOptions options)

-- Test Labels -----------------------------------------------------------------

data SerialTestLabel
  = SerialZstdEnable
  deriving (Enum, Eq, Ord, Show)

-- Test Combinators ------------------------------------------------------------

diffWireOptions ::
  WireEncodeOptions ->
  WireDecodeOptions ->
  PropertyT IO ()
diffWireOptions encodeOptions decodeOptions = do
  let encodeZstd = Serial.isEncodeCompressed encodeOptions
  let decodeZstd = Serial.isDecodeCompressed decodeOptions

  -- Coherence check the serialization options provided. The encoding and
  -- decoding options should always agree (be equal).
  --
  -- Enabled compression with disabled decompression, or vice versa,
  -- constitutes a test failure
  Hedgehog.diff encodeZstd (==) decodeZstd

  -- Label the test with a 'WireZstdEnable' test label if compression is enabled
  -- in both @encodeOptions@ and @decodeOptions@.
  --
  -- This is used to track feature coverage across tests.
  when (encodeZstd && decodeZstd) (Hedgehog.collect SerialZstdEnable)