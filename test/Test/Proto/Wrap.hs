-- | Hedgehog property tests for 'Wrap' and wrapped MQTT messages.
module Test.Proto.Wrap (tests) where

import Test.Tasty (TestTree, testGroup)

import Test.Proto.Wrap.Packet qualified
import Test.Proto.Wrap.Request qualified
import Test.Proto.Wrap.Response qualified
import Test.Proto.Wrap.Stream qualified

-- -----------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Test.Proto.Wrap"
    [ Test.Proto.Wrap.Packet.tests
    , Test.Proto.Wrap.Request.tests
    , Test.Proto.Wrap.Response.tests
    , Test.Proto.Wrap.Stream.tests
    ]
