-- | TODO
--
-- @since 0.1.0.0
module Network.GRPC.MQTT.Option
  ( -- * TODO

    -- * File Options

    -- * Option Types


    -- ** Batched
    -- $option-batched
    Batched (Batch, Batched, Unbatched, getBatched),

    -- ** CLevel
    -- $option-clevel
    CLevel (CLevel, getCLevel),
    fromCLevel,
    toCLevel,
  )
where

---------------------------------------------------------------------------------

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Option.Batched
  ( Batched (Batch, Batched, Unbatched, getBatched),
  )
import Network.GRPC.MQTT.Option.CLevel
  ( CLevel (CLevel, getCLevel),
    fromCLevel,
    toCLevel,
  )

---------------------------------------------------------------------------------

-- File Options -----------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0

-- Service Options --------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0

-- Method Options ---------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0

-- Option Types -----------------------------------------------------------------

-- | TODO
--
-- @since 0.1.0.0

-- Batched ----------------------------------------------------------------------

-- $option-batched
--
-- Documentation on the 'Batched' protobuf option and details on batched
-- streams, can be foud in the "Network.GRPC.MQTT.Option.Batched" module.

-- CLevel -----------------------------------------------------------------------

-- $option-clevel
--
-- TODO
