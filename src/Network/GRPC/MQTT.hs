-- Disable import lists, avoid enumerating the constructors for
-- 'Network.MQTT.Client.Property' (there are a lot), this is fine because this
-- module is only managing re-exports.
{-# OPTIONS_GHC -Wno-missing-import-lists #-}

-- | Copyright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
module Network.GRPC.MQTT
  ( -- * 'net-mqtt' Re-exports
    module Network.MQTT.Client,
    module Network.MQTT.Topic
  )
where

--------------------------------------------------------------------------------

import Network.MQTT.Client
  ( MQTTException (..),
    ProtocolLevel (..),
    Property (..),
    LastWill (..)
  )
import Network.MQTT.Topic
  ( Topic (unTopic),
    mkTopic,
  )
