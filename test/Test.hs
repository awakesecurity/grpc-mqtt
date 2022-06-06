{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE ImplicitPrelude #-}

-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.

module Main (main) where

---------------------------------------------------------------------------------

import Test.Tasty
  ( TestTree,
    defaultMainWithIngredients,
    includingOptions,
    testGroup,
  )
import Test.Tasty.Runners (NumThreads)
import Test.Tasty.Ingredients (Ingredient)
import Test.Tasty.Ingredients.Basic (listingTests)
import Test.Tasty.Ingredients.ConsoleReporter (consoleTestReporter)
import Test.Tasty.Options (OptionDescription (Option))

import Data.Proxy (Proxy (Proxy))

import Network.GRPC.HighLevel.Client (Host, Port)
import Network.MQTT.Topic (Topic)

---------------------------------------------------------------------------------

import Test.Suite.Config (TestOption)

import qualified Test.Network.GRPC.HighLevel.Extra
import qualified Test.Network.GRPC.MQTT.Message.Packet
import qualified Test.Network.GRPC.MQTT.Message.Request
import qualified Test.Service

---------------------------------------------------------------------------------

main :: IO ()
main =
  defaultMainWithIngredients
    testIngredients
    testTree

testTree :: TestTree
testTree =
  testGroup
    "Tests: grpc-mqtt"
    [ Test.Network.GRPC.HighLevel.Extra.tests
    , Test.Network.GRPC.MQTT.Message.Packet.tests
    , Test.Network.GRPC.MQTT.Message.Request.tests
    , Test.Service.tests
    ]

testIngredients :: [Ingredient]
testIngredients =
  [ listingTests
  , consoleTestReporter
  , includingOptions testOptions
  ]

testOptions :: [OptionDescription]
testOptions =
  [ Option (Proxy @NumThreads)
  , Option (Proxy @(TestOption "broker-port" Port))
  , Option (Proxy @(TestOption "server-port" Port))
  , Option (Proxy @(TestOption "server-host" Host))
  , Option (Proxy @(TestOption "base-topic" Topic))
  , Option (Proxy @(TestOption "client-id" String))
  , Option (Proxy @(TestOption "remote-id" String))
  ]
