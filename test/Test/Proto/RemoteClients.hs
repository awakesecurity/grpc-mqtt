-- Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -Wno-unused-imports #-}

module Test.Proto.RemoteClients
  ( testServiceRemoteClientMethodMap,
  )
where

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.TH.RemoteClient (mqttRemoteClientMethodMap)
import Network.GRPC.MQTT.Option.Batched (Batched (Unbatched))

import Proto.Service
  ( TestService (TestService),
    testServiceBatchBiDiStreamCall,
    testServiceBatchClientStreamCall,
    testServiceBatchServerStreamCall,
    testServiceBiDiStreamCall,
    testServiceClient,
    testServiceClientStreamCall,
#if MIN_VERSION_proto3_suite(0,4,3)
    testServicenormalCall,
#else
    testServiceNormalCall,
#endif
    testServiceServerStreamCall,
  )

---------------------------------------------------------------------------------

$(mqttRemoteClientMethodMap "test/Proto/Service.proto" Unbatched)
