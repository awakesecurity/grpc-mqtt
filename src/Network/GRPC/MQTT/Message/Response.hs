{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      :  Network.GRPC.MQTT.Message.Response
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- @since 1.0.0
module Network.GRPC.MQTT.Message.Response
  ( -- * Wire Encoding

    -- * Wire Decoding
    unwrapResponse,
    unwrapUnaryResponse,
    unwrapClientStreamResponse,
    unwrapServerStreamResponse,
    unwrapBiDiStreamResponse,

    -- * Response Handlers
    makeResponseSender,
    makeErrorResponseSender,
    makeNormalResponseReader,
    makeClientResponseReader,
    makeServerResponseReader,
    makeBiDiResponseReader,
  )
where

--------------------------------------------------------------------------------

import Control.Concurrent.STM.TQueue (TQueue)
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

import Network.MQTT.Client (MQTTClient, QoS (QoS1), publishq)
import Network.MQTT.Topic (Topic)

import Proto3.Suite.Class (Message)

import Relude

import UnliftIO (MonadUnliftIO)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message qualified as Message
import Network.GRPC.MQTT.Message.Packet qualified as Packet

import Network.GRPC.MQTT.Serial (WireDecodeOptions, WireEncodeOptions)

import Network.GRPC.MQTT.Types (MQTTResult (GRPCResult, MQTTError), RemoteResult (..))

import Network.GRPC.MQTT.Wrapping qualified as Wrapping

import Network.GRPC.MQTT.Wrapping (parseErrorToRCE)
import Network.GRPC.LowLevel (NormalRequestResult (..))
import Proto.Mqtt
  ( MQTTResponse (..),
    RemoteError,
    ResponseBody (ResponseBody, responseBodyValue),
    WrappedResponse (WrappedResponse),
    WrappedResponseOrError
      ( WrappedResponseOrErrorError,
        WrappedResponseOrErrorResponse
      ),
  )

-- Response - Wire Encoding ----------------------------------------------------

wireEncodeResponse ::
  WireEncodeOptions ->
  RemoteResult s ->
  ByteString
wireEncodeResponse options result = Message.toWireEncoded options (wrapResponse result)

wireEncodeErrorResponse ::
  WireEncodeOptions ->
  RemoteError ->
  ByteString
wireEncodeErrorResponse options err =
  let response :: WrappedResponse
      response = WrappedResponse (Just (WrappedResponseOrErrorError err))
   in Message.toWireEncoded options response

wrapResponse :: RemoteResult s -> WrappedResponse
wrapResponse res =
  WrappedResponse . Just $
    case res of
      RemoteNormalResult NormalRequestResult{rspBody, initMD, trailMD, rspCode, details} ->
        WrappedResponseOrErrorResponse $
          MQTTResponse
            (Just $ ResponseBody rspBody)
            (Just $ Wrapping.fromMetadataMap initMD)
            (Just $ Wrapping.fromMetadataMap trailMD)
            (Wrapping.fromStatusCode rspCode)
            (Wrapping.fromStatusDetails details)
      RemoteWriterResult (rspBody, initMD, trailMD, rspCode, details) ->
        WrappedResponseOrErrorResponse $
          MQTTResponse
            (ResponseBody <$> rspBody)
            (Just $ Wrapping.fromMetadataMap initMD)
            (Just $ Wrapping.fromMetadataMap trailMD)
            (Wrapping.fromStatusCode rspCode)
            (Wrapping.fromStatusDetails details)
      RemoteReaderResult (rspMetadata, statusCode, details) ->
        WrappedResponseOrErrorResponse $
          MQTTResponse
            Nothing
            Nothing
            (Just $ Wrapping.fromMetadataMap rspMetadata)
            (Wrapping.fromStatusCode statusCode)
            (Wrapping.fromStatusDetails details)
      RemoteBiDiResult (rspMetadata, statusCode, details) ->
        WrappedResponseOrErrorResponse $
          MQTTResponse
            Nothing
            Nothing
            (Just $ Wrapping.fromMetadataMap rspMetadata)
            (Wrapping.fromStatusCode statusCode)
            (Wrapping.fromStatusDetails details)
      RemoteErrorResult err ->
        WrappedResponseOrErrorError $ Wrapping.toRemoteError err

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
  WireDecodeOptions ->
  ByteString ->
  m (ParsedMQTTResponse ByteString)
unwrapResponse options bytes = do
  MQTTResponse{..} <-
    case Message.fromWireEncoded @_ @WrappedResponse options bytes of
      Left err -> throwError (Message.toRemoteError err)
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
  WireDecodeOptions ->
  ByteString ->
  m (ParsedMQTTResponse a)
decodeResponse options bytes = do
  response <- unwrapResponse options bytes
  for response \body -> do
    case Message.fromWireEncoded options body of
      Left err -> throwError (Message.toRemoteError err)
      Right rx -> pure rx

unwrapUnaryResponse ::
  forall m rsp.
  (MonadError RemoteError m, Message rsp) =>
  WireDecodeOptions ->
  ByteString ->
  m (MQTTResult 'Normal rsp)
unwrapUnaryResponse options =
  fmap toNormalResult . decodeResponse options
  where
    toNormalResult :: ParsedMQTTResponse rsp -> MQTTResult 'Normal rsp
    toNormalResult ParsedMQTTResponse{..} =
      case responseBody of
        Nothing -> MQTTError "Empty response body"
        (Just body) -> GRPCResult $ ClientNormalResponse body initMetadata trailMetadata statusCode statusDetails

unwrapClientStreamResponse ::
  forall m rsp.
  (MonadError RemoteError m, Message rsp) =>
  WireDecodeOptions ->
  ByteString ->
  m (MQTTResult 'ClientStreaming rsp)
unwrapClientStreamResponse options =
  fmap toClientStreamResult . decodeResponse options
  where
    toClientStreamResult :: ParsedMQTTResponse rsp -> MQTTResult 'ClientStreaming rsp
    toClientStreamResult ParsedMQTTResponse{..} =
      GRPCResult $ ClientWriterResponse responseBody initMetadata trailMetadata statusCode statusDetails

unwrapServerStreamResponse ::
  forall m rsp.
  (MonadError RemoteError m, Message rsp) =>
  WireDecodeOptions ->
  ByteString ->
  m (MQTTResult 'ServerStreaming rsp)
unwrapServerStreamResponse options =
  fmap toServerStreamResult . decodeResponse options
  where
    toServerStreamResult :: ParsedMQTTResponse rsp -> MQTTResult 'ServerStreaming rsp
    toServerStreamResult ParsedMQTTResponse{..} =
      GRPCResult $ ClientReaderResponse trailMetadata statusCode statusDetails

unwrapBiDiStreamResponse ::
  forall m rsp.
  (MonadError RemoteError m, Message rsp) =>
  WireDecodeOptions ->
  ByteString ->
  m (MQTTResult 'BiDiStreaming rsp)
unwrapBiDiStreamResponse options =
  fmap toBiDiStreamResult . decodeResponse options
  where
    toBiDiStreamResult :: ParsedMQTTResponse rsp -> MQTTResult 'BiDiStreaming rsp
    toBiDiStreamResult ParsedMQTTResponse{..} =
      GRPCResult $ ClientBiDiResponse trailMetadata statusCode statusDetails

-- Response Handlers -----------------------------------------------------------

makeResponseSender ::
  MonadUnliftIO m =>
  MQTTClient ->
  Topic ->
  Word32 ->
  Maybe Natural ->
  WireEncodeOptions ->
  RemoteResult s ->
  m ()
makeResponseSender client topic packetSizeLimit rateLimit options response =
  let message :: ByteString
      message = wireEncodeResponse options response
   in Packet.makePacketSender packetSizeLimit rateLimit (liftIO . publish) message
  where
    publish :: ByteString -> IO ()
    publish bytes = publishq client topic (fromStrict bytes) False QoS1 []

makeErrorResponseSender ::
  MonadUnliftIO m =>
  MQTTClient ->
  Topic ->
  Word32 ->
  Maybe Natural -> 
  WireEncodeOptions ->
  RemoteError ->
  m ()
makeErrorResponseSender client topic packetSizeLimit rateLimit options err = do
  let message :: ByteString
      message = wireEncodeErrorResponse options err
   in Packet.makePacketSender packetSizeLimit rateLimit (liftIO . publish) message
  where
    publish :: ByteString -> IO ()
    publish bytes = publishq client topic (fromStrict bytes) False QoS1 []

makeNormalResponseReader ::
  (MonadIO m, MonadError RemoteError m, Message a) =>
  TQueue ByteString ->
  WireDecodeOptions ->
  m (MQTTResult 'Normal a)
makeNormalResponseReader channel options = do
  runExceptT (Packet.makePacketReader channel) >>= \case
    Left err -> throwError (parseErrorToRCE err)
    Right bs -> unwrapUnaryResponse options bs

makeClientResponseReader ::
  (MonadIO m, MonadError RemoteError m, Message a) =>
  TQueue ByteString ->
  WireDecodeOptions ->
  m (MQTTResult 'ClientStreaming a)
makeClientResponseReader channel options = do
  runExceptT (Packet.makePacketReader channel) >>= \case
    Left err -> throwError (parseErrorToRCE err)
    Right bs -> unwrapClientStreamResponse options bs

makeServerResponseReader ::
  (MonadIO m, MonadError RemoteError m, Message a) =>
  TQueue ByteString ->
  WireDecodeOptions ->
  m (MQTTResult 'ServerStreaming a)
makeServerResponseReader channel options = do
  runExceptT (Packet.makePacketReader channel) >>= \case
    Left err -> throwError (parseErrorToRCE err)
    Right bs -> unwrapServerStreamResponse options bs

makeBiDiResponseReader ::
  (MonadIO m, MonadError RemoteError m, Message a) =>
  TQueue ByteString ->
  WireDecodeOptions ->
  m (MQTTResult 'BiDiStreaming a)
makeBiDiResponseReader channel options =
  runExceptT (Packet.makePacketReader channel) >>= \case
    Left err -> throwError (parseErrorToRCE err)
    Right bs -> unwrapBiDiStreamResponse options bs
