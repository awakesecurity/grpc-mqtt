-- | Hedgehog generators for us in the @Test.Proto.Wrap@ module group.
module Test.Proto.Wrap.Gen
  ( -- * Hedgehog Generators
    seqInfo,
    metadataMap,
    packet,
    request,
    response,
    stream,
  )
where

import Hedgehog (MonadGen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

import Network.GRPC.HighLevel (MetadataMap (MetadataMap))

import Network.GRPC.MQTT.Wrap.Stream (Stream)
import Network.GRPC.MQTT.Wrap.Request (Request (Request))
import Network.GRPC.MQTT.Wrap.Response (Response (Response))
import Network.GRPC.MQTT.Wrap.Packet (Packet (Packet), SeqInfo, fromSeqIx)

-- -----------------------------------------------------------------------------

-- | 'Wrap' generator combinator.
-- wrapping :: MonadGen m => m a -> m (Wrap a)
-- wrapping = _

-- | 'SeqInfo' generator combinator.
seqInfo :: MonadGen m => m SeqInfo
seqInfo = fromSeqIx <$> Gen.word32 Range.constantBounded

-- | 'MetadataMap' generator dependent on Hedgehog's size parameter.
metadataMap :: MonadGen m => m MetadataMap
metadataMap = do
  lenMap <- Gen.sized (Gen.int . Range.linear 0 . fromIntegral)
  MetadataMap <$> Gen.map (Range.linear 0 lenMap) do
    liftA2 (,) sized'bytes (sized'list sized'bytes)

-- | 'Packet' generator dependent on Hedgehog's size parameter.
packet :: MonadGen m => m Packet
packet = Packet <$> seqInfo <*> sized'bytes

-- | 'Request' generator dependent on Hedgehog's size parameter.
request :: MonadGen m => m Request
request =
  Request
    <$> Gen.int64 Range.constantBounded
    <*> metadataMap
    <*> sized'bytes

-- | 'Response' generator dependent on Hedgehog's size parameter.
response :: MonadGen m => m Response
response =
  Response
    <$> sized'bytes
    <*> metadataMap
    <*> metadataMap
    <*> Gen.int32 Range.constantBounded
    <*> sized'text

-- | 'Stream' generator dependent on Hedgehog's size parameter.
stream :: MonadGen m => m Stream
stream = fromList <$> sized'list sized'bytes

-- | 'Stream' generator dependent on Hedgehog's size parameter.
-- remoteError :: MonadGen m => m RemoteError
-- remoteError =

-- -----------------------------------------------------------------------------
--
-- Primitive Generators
--

sized'list :: MonadGen m => m a -> m [a]
sized'list itemG = Gen.sized \sz -> do
  len <- Gen.int (Range.linear 0 (fromIntegral sz))
  Gen.list (Range.linear 0 len) itemG

sized'bytes :: MonadGen m => m ByteString
sized'bytes = Gen.sized \sz -> do
  len <- Gen.int (Range.linear 0 (fromIntegral sz))
  Gen.bytes (Range.linear 0 len)

sized'text :: MonadGen m => m Text
sized'text = Gen.sized \sz -> do
  len <- Gen.int (Range.linear 0 (fromIntegral sz))
  Gen.text (Range.linear 0 len) Gen.unicode
