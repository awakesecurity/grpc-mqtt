{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | TODO
--
-- @since 1.0.0
module Test.Request.Gen
  ( -- * TODO
    normalRequest,
    clientStreamRequest,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (MonadGen)

--------------------------------------------------------------------------------

import Data.Foldable (traverse_)

import Network.GRPC.HighLevel.Client qualified as GRPC.Client

import Network.GRPC.MQTT.Types (MQTTRequest)
import Network.GRPC.MQTT.Types qualified as GRPC.MQTT

--------------------------------------------------------------------------------

import Test.Network.GRPC.HighLevel.Extra.Gen qualified as Gen

--------------------------------------------------------------------------------

-- | TODO
normalRequest ::
  MonadGen m =>
  rqt ->
  m (MQTTRequest 'GRPC.Client.Normal rqt rsp)
normalRequest body = do
  metadata <- Gen.metadataMap
  pure (GRPC.MQTT.MQTTNormalRequest body 5 metadata)

-- | TODO
clientStreamRequest ::
  forall m rqt rsp.
  MonadGen m =>
  [rqt] ->
  m (MQTTRequest 'GRPC.Client.ClientStreaming rqt rsp)
clientStreamRequest rqts = do
  metadata <- Gen.metadataMap
  pure (GRPC.MQTT.MQTTWriterRequest 5 metadata clientStreamHandler)
  where
    clientStreamHandler :: GRPC.Client.StreamSend rqt -> IO ()
    clientStreamHandler send = traverse_ send rqts
