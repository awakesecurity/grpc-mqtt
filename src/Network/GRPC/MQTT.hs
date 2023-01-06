-- Disable import lists, avoid enumerating the constructors for
-- 'Network.MQTT.Client.Property' (there are a lot), this is fine because this
-- module is only managing re-exports.
{-# OPTIONS_GHC -Wno-missing-import-lists #-}

-- |
-- Module      :  Network.GRPC.MQTT
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- @since 1.0.0
module Network.GRPC.MQTT
  ( -- * 'net-mqtt' Re-exports
    module Network.MQTT.Client,
    module Network.MQTT.Topic,
  )
where

--------------------------------------------------------------------------------

import Network.MQTT.Client
  ( LastWill (..),
    MQTTException (..),
    Property (..),
    ProtocolLevel (..),
  )
import Network.MQTT.Topic
  ( Topic (unTopic),
    mkTopic,
  )
