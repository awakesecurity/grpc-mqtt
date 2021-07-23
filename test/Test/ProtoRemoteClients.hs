{- 
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}

{-# LANGUAGE TemplateHaskell #-}

module Test.ProtoRemoteClients where

import Network.GRPC.MQTT.TH.RemoteClient
import Proto.Test

-- addHelloRemoteClientMethodMap :: Client -> IO MethodMap
-- addHelloRemoteClientMethodMap grpcClient = do
--   ah <- addHelloClient grpcClient
--   return $ fromList
--     [ ("/test.AddHello/Add", wrapUnaryClientHandler $ addHelloAdd ah)
--     , ("/test.AddHello/HelloSS", wrapServerStreamingClientHandler $ addHelloHelloSS ah)
--     ]

-- multGoodbyeRemoteClientMethodMap :: Client -> IO MethodMap
-- multGoodbyeRemoteClientMethodMap grpcClient = do
--   mg <- multGoodbyeClient grpcClient
--   return $ fromList
--     [ ("/test.MultGoodbye/Mult", wrapUnaryClientHandler $ multGoodbyeMult mg)
--     , ("/test.MultGoodbye/GoodbyeSS", wrapServerStreamingClientHandler $ multGoodbyeGoodbyeSS mg)
--     ]

$(mqttRemoteClientMethodMap "proto/test.proto")
