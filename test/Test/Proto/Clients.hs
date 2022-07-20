-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -Wno-unused-imports #-}

module Test.Proto.Clients
  ( testServiceMqttClient,
  )
where

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.TH.Client (makeMQTTClientFuncs)

import Proto.Service
  ( TestService (TestService),
    testServiceBatchBiDiStreamCall,
    testServiceBatchClientStreamCall,
    testServiceBatchServerStreamCall,
    testServiceBiDiStreamCall,
    testServiceClientStreamCall,
    testServiceNormalCall,
    testServiceServerStreamCall,
  )

---------------------------------------------------------------------------------

$(makeMQTTClientFuncs "test/Proto/Service.proto")
