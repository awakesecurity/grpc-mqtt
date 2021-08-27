{- 
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}

{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TemplateHaskell #-}

module Test.ProtoClients where

import Network.GRPC.MQTT.TH.Client
import Proto.Test

$(mqttClientFuncs "proto/test.proto")
