{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Message.Response
  ( -- * Wire Encoding

    -- * Wire Decoding
    unwrapResponse,
    unwrapUnaryResponse,
    unwrapClientStreamResponse,
    unwrapServerStreamResponse,
    unwrapBiDiStreamResponse,
  )
where

--------------------------------------------------------------------------------

import Control.Concurrent.STM.TChan (TChan)
import Control.Monad.Except (MonadError, throwError)

import Data.Traversable (for)

import Network.GRPC.HighLevel as HL
  ( MetadataMap,
    StatusCode,
    StatusDetails (..),
  )
import Network.GRPC.HighLevel.Client
  ( ClientResult
      ( ClientBiDiResponse,
        ClientNormalResponse,
        ClientReaderResponse,
        ClientWriterResponse
      ),
    GRPCMethodType (BiDiStreaming, ClientStreaming, Normal, ServerStreaming),
  )

import Proto3.Suite (fromByteString)
import Proto3.Suite.Class (Message)

import Relude

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Packet qualified as Packet

import Network.GRPC.MQTT.Serial (WireDecodeOptions)

import Network.GRPC.MQTT.Types (MQTTResult (GRPCResult, MQTTError))

import Network.GRPC.MQTT.Wrapping qualified as Wrapping

import Proto.Mqtt
  ( MQTTResponse (..),
    RemoteError,
    ResponseBody (responseBodyValue),
    WrappedResponse (WrappedResponse),
    WrappedResponseOrError
      ( WrappedResponseOrErrorError,
        WrappedResponseOrErrorResponse
      ),
  )

-- Response - Wire Encoding ----------------------------------------------------

-- Response - Wire Decoding ----------------------------------------------------

data ParsedMQTTResponse response = ParsedMQTTResponse
  { responseBody :: Maybe response
  , initMetadata :: MetadataMap
  , trailMetadata :: MetadataMap
  , statusCode :: StatusCode
  , statusDetails :: StatusDetails
  }
  deriving stock (Functor, Foldable, Traversable)

unwrapResponse ::
  MonadError RemoteError m =>
  ByteString ->
  m (ParsedMQTTResponse ByteString)
unwrapResponse bytes = do
  MQTTResponse{..} <-
    case fromByteString @WrappedResponse bytes of
      Left err -> throwError (Wrapping.parseErrorToRCE err)
      Right (WrappedResponse Nothing) -> throwError (Wrapping.remoteError "Empty response")
      Right (WrappedResponse (Just (WrappedResponseOrErrorError err))) -> throwError err
      Right (WrappedResponse (Just (WrappedResponseOrErrorResponse rsp))) -> pure rsp

  statusCode <-
    case Wrapping.toStatusCode mqttresponseResponseCode of
      Nothing -> throwError (Wrapping.remoteError ("Invalid reponse code: " <> Relude.show mqttresponseResponseCode))
      Just sc -> pure sc

  return $
    ParsedMQTTResponse
      (responseBodyValue <$> mqttresponseBody)
      (maybe mempty Wrapping.toMetadataMap mqttresponseInitMetamap)
      (maybe mempty Wrapping.toMetadataMap mqttresponseTrailMetamap)
      statusCode
      (Wrapping.toStatusDetails mqttresponseDetails)

decodeResponse ::
  (MonadError RemoteError m, Message a) =>
  ByteString ->
  m (ParsedMQTTResponse a)
decodeResponse bytes = do
  response <- unwrapResponse bytes
  for response \body -> do
    case fromByteString body of
      Left err -> throwError (Wrapping.parseErrorToRCE err)
      Right rx -> pure rx

unwrapUnaryResponse ::
  forall m rsp.
  (MonadError RemoteError m, Message rsp) =>
  ByteString ->
  m (MQTTResult 'Normal rsp)
unwrapUnaryResponse = fmap toNormalResult . decodeResponse
  where
    toNormalResult :: ParsedMQTTResponse rsp -> MQTTResult 'Normal rsp
    toNormalResult ParsedMQTTResponse{..} =
      case responseBody of
        Nothing -> MQTTError "Empty response body"
        (Just body) -> GRPCResult $ ClientNormalResponse body initMetadata trailMetadata statusCode statusDetails

unwrapClientStreamResponse ::
  forall m rsp.
  (MonadError RemoteError m, Message rsp) =>
  ByteString ->
  m (MQTTResult 'ClientStreaming rsp)
unwrapClientStreamResponse = fmap toClientStreamResult . decodeResponse
  where
    toClientStreamResult :: ParsedMQTTResponse rsp -> MQTTResult 'ClientStreaming rsp
    toClientStreamResult ParsedMQTTResponse{..} =
      GRPCResult $ ClientWriterResponse responseBody initMetadata trailMetadata statusCode statusDetails

unwrapServerStreamResponse ::
  forall m rsp.
  (MonadError RemoteError m, Message rsp) =>
  ByteString ->
  m (MQTTResult 'ServerStreaming rsp)
unwrapServerStreamResponse = fmap toServerStreamResult . decodeResponse
  where
    toServerStreamResult :: ParsedMQTTResponse rsp -> MQTTResult 'ServerStreaming rsp
    toServerStreamResult ParsedMQTTResponse{..} =
      GRPCResult $ ClientReaderResponse trailMetadata statusCode statusDetails

unwrapBiDiStreamResponse ::
  forall m rsp.
  (MonadError RemoteError m, Message rsp) =>
  ByteString ->
  m (MQTTResult 'BiDiStreaming rsp)
unwrapBiDiStreamResponse = fmap toBiDiStreamResult . decodeResponse
  where
    toBiDiStreamResult :: ParsedMQTTResponse rsp -> MQTTResult 'BiDiStreaming rsp
    toBiDiStreamResult ParsedMQTTResponse{..} =
      GRPCResult $ ClientBiDiResponse trailMetadata statusCode statusDetails
