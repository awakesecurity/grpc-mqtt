-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TemplateHaskell #-}

module Test.Proto.RemoteClients
  ( testServiceRemoteClientMethodMap,
  )
where

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.TH.RemoteClient (mqttRemoteClientMethodMap)
import Network.GRPC.MQTT.Types (Batched (Unbatched))

import Proto.Service
  ( TestService (TestService),
    testServiceBatchBiDiStreamCall,
    testServiceBatchClientStreamCall,
    testServiceBatchServerStreamCall,
    testServiceBiDiStreamCall,
    testServiceClient,
    testServiceClientStreamCall,
    testServiceNormalCall,
    testServiceServerStreamCall,
  )

---------------------------------------------------------------------------------

$(mqttRemoteClientMethodMap "test/proto/service.proto" Unbatched)
