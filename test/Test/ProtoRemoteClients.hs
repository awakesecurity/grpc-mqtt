{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE TemplateHaskell #-}

module Test.ProtoRemoteClients where

import Network.GRPC.MQTT.TH.RemoteClient
import Proto.Test

$(mqttRemoteClientMethodMap "proto/test.proto" Unbatched)
