-- | TODO
--
-- @since 0.1.0.0
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

-- Aux Control -----------------------------------------------------------------