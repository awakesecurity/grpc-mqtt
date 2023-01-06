-- |
-- Module      :  Network.GRPC.MQTT.Message.AuxControl
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- This module exports definitions for the 'AuxControlMessage' message type.
--
-- @since 1.0.0
module Network.GRPC.MQTT.Message.AuxControl
  ( -- * Aux Message
    AuxControlMessage
      ( AuxControlMessage,
        AuxMessageAlive,
        AuxMessageTerminate,
        AuxMessageUnknown
      ),

    -- * Aux Control
    AuxControl
      ( AuxControlAlive,
        AuxControlTerminate,
        AuxControlUnknown
      ),
  )
where

--------------------------------------------------------------------------------

import Proto3.Suite (Enumerated (Enumerated))

import Relude

--------------------------------------------------------------------------------

import Proto.Mqtt
  ( AuxControl (AuxControlAlive, AuxControlTerminate, AuxControlUnknown),
    AuxControlMessage (AuxControlMessage),
  )

-- Aux Message -----------------------------------------------------------------

pattern AuxMessageAlive :: AuxControlMessage
pattern AuxMessageAlive = AuxControlMessage (Enumerated (Right AuxControlAlive))

pattern AuxMessageTerminate :: AuxControlMessage
pattern AuxMessageTerminate = AuxControlMessage (Enumerated (Right AuxControlTerminate))

pattern AuxMessageUnknown :: AuxControlMessage
pattern AuxMessageUnknown = AuxControlMessage (Enumerated (Right AuxControlUnknown))