module Test.Network.GRPC.MQTT.Compress.Gen
  ( binary,
  )
where

---------------------------------------------------------------------------------

import Hedgehog (MonadGen, Range)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

---------------------------------------------------------------------------------

import Relude

----------------------------------------------------------------------------------

-- | TODO
binary :: MonadGen m => Range Int -> m ByteString
binary len'range =
  let bin'range :: Range Word8 
      bin'range = Range.constant 0 1 
   in fromList <$> Gen.list len'range (Gen.word8 bin'range)
