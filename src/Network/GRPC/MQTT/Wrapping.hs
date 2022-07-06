{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Wrapping
  ( fromLazyByteString,
    fromRemoteError,
    parseMessageOrError,
    remoteError,
    toRemoteError,
    toGRPCIOError,
    toMetadataMap,
    fromMetadataMap,
    wrapResponse,
    unwrapUnaryResponse,
    unwrapClientStreamResponse,
    unwrapServerStreamResponse,
    wrapUnaryClientHandler,
    wrapClientStreamingClientHandler,
    wrapServerStreamingClientHandler,
    wrapBiDiStreamingClientHandler,
    unwrapBiDiStreamResponse,
    parseErrorToRCE,
  )
where

--------------------------------------------------------------------------------

import Control.Monad.Except (MonadError, throwError)

import Data.Traversable (for)

import Relude

import Network.GRPC.MQTT.Types
  ( ClientHandler
      ( ClientBiDiStreamHandler,
        ClientClientStreamHandler,
        ClientServerStreamHandler,
        ClientUnaryHandler
      ),
    MQTTResult (..),
  )

import Proto.Mqtt as Proto
  ( MQTTResponse (..),
    MetadataMap (MetadataMap),
    MetadataMap_Entry (MetadataMap_Entry),
    RError (..),
    RemoteError (..),
    RemoteErrorExtra (..),
    ResponseBody (ResponseBody, responseBodyValue),
    WrappedResponse (WrappedResponse),
    WrappedResponseOrError
      ( WrappedResponseOrErrorError,
        WrappedResponseOrErrorResponse
      ),
  )

import Control.Exception (ErrorCall, try)
import Data.Map qualified as M
import Data.Vector qualified as V
import GHC.IO.Unsafe (unsafePerformIO)
import Network.GRPC.HighLevel as HL
  ( GRPCIOError (..),
    MetadataMap (MetadataMap),
    StatusCode,
    StatusDetails (..),
  )
import Network.GRPC.HighLevel.Client
  ( ClientError (..),
    ClientRequest (ClientBiDiRequest, ClientNormalRequest, ClientReaderRequest, ClientWriterRequest),
    ClientResult
      ( ClientBiDiResponse,
        ClientErrorResponse,
        ClientNormalResponse,
        ClientReaderResponse,
        ClientWriterResponse
      ),
    GRPCMethodType (BiDiStreaming, ClientStreaming, Normal, ServerStreaming),
  )
import Network.GRPC.Unsafe (CallError (..))
import Proto3.Suite
  ( Enumerated (Enumerated),
    Message,
    fromByteString,
  )
import Proto3.Wire.Decode (ParseError (..))

---------------------------------------------------------------------------------

import Network.GRPC.MQTT.Option.Batched (Batched)

---------------------------------------------------------------------------------

-- Client Handler Wrappers
wrapUnaryClientHandler ::
  (Message request, Message response) =>
  (ClientRequest 'Normal request response -> IO (ClientResult 'Normal response)) ->
  ClientHandler
wrapUnaryClientHandler handler =
  ClientUnaryHandler $ \raw timeout metadata ->
    case fromByteString raw of
      Left err -> pure $ ClientErrorResponse (ClientErrorNoParse err)
      Right msg -> handler (ClientNormalRequest msg timeout metadata)

wrapServerStreamingClientHandler ::
  (Message request, Message response) =>
  Batched ->
  (ClientRequest 'ServerStreaming request response -> IO (ClientResult 'ServerStreaming response)) ->
  ClientHandler
wrapServerStreamingClientHandler useBatchedStream handler =
  ClientServerStreamHandler useBatchedStream $ \rawRequest timeout metadata recv ->
    case fromByteString rawRequest of
      Left err -> pure $ ClientErrorResponse (ClientErrorNoParse err)
      Right req -> handler (ClientReaderRequest req timeout metadata recv)

wrapClientStreamingClientHandler ::
  (Message request, Message response) =>
  (ClientRequest 'ClientStreaming request response -> IO (ClientResult 'ClientStreaming response)) ->
  ClientHandler
wrapClientStreamingClientHandler handler =
  ClientClientStreamHandler $ \timeout metadata send -> do
    handler (ClientWriterRequest timeout metadata send)

wrapBiDiStreamingClientHandler ::
  (Message request, Message response) =>
  Batched ->
  (ClientRequest 'BiDiStreaming request response -> IO (ClientResult 'BiDiStreaming response)) ->
  ClientHandler
wrapBiDiStreamingClientHandler useBatchedStream handler =
  ClientBiDiStreamHandler useBatchedStream $ \timeout metadata bidi -> do
    handler (ClientBiDiRequest timeout metadata bidi)

-- Responses
wrapResponse :: ClientResult s ByteString -> WrappedResponse
wrapResponse res =
  WrappedResponse . Just $
    case res of
      ClientNormalResponse rspBody initMD trailMD rspCode details ->
        WrappedResponseOrErrorResponse $
          MQTTResponse
            (Just $ ResponseBody rspBody)
            (Just $ fromMetadataMap initMD)
            (Just $ fromMetadataMap trailMD)
            (fromStatusCode rspCode)
            (fromStatusDetails details)
      ClientWriterResponse rspBody initMD trailMD rspCode details ->
        WrappedResponseOrErrorResponse $
          MQTTResponse
            (ResponseBody <$> rspBody)
            (Just $ fromMetadataMap initMD)
            (Just $ fromMetadataMap trailMD)
            (fromStatusCode rspCode)
            (fromStatusDetails details)
      ClientReaderResponse rspMetadata statusCode details ->
        WrappedResponseOrErrorResponse $
          MQTTResponse
            Nothing
            Nothing
            (Just $ fromMetadataMap rspMetadata)
            (fromStatusCode statusCode)
            (fromStatusDetails details)
      ClientBiDiResponse rspMetadata statusCode details ->
        WrappedResponseOrErrorResponse $
          MQTTResponse
            Nothing
            Nothing
            (Just $ fromMetadataMap rspMetadata)
            (fromStatusCode statusCode)
            (fromStatusDetails details)
      ClientErrorResponse err ->
        WrappedResponseOrErrorError $ toRemoteError err

data ParsedMQTTResponse response = ParsedMQTTResponse
  { responseBody :: Maybe response
  , initMetadata :: HL.MetadataMap
  , trailMetadata :: HL.MetadataMap
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
      Left err -> throwError (parseErrorToRCE err)
      Right (WrappedResponse Nothing) -> throwError (remoteError "Empty response")
      Right (WrappedResponse (Just (WrappedResponseOrErrorError err))) -> throwError err
      Right (WrappedResponse (Just (WrappedResponseOrErrorResponse rsp))) -> pure rsp

  let initMetadata = maybe mempty toMetadataMap mqttresponseInitMetamap
  let trailMetadata = maybe mempty toMetadataMap mqttresponseTrailMetamap

  statusCode <-
    case toStatusCode mqttresponseResponseCode of
      Nothing -> throwError (remoteError ("Invalid reponse code: " <> Relude.show mqttresponseResponseCode))
      Just sc -> pure sc

  let statusDetails = toStatusDetails mqttresponseDetails

  return $
    ParsedMQTTResponse
      (responseBodyValue <$> mqttresponseBody)
      initMetadata
      trailMetadata
      statusCode
      statusDetails

decodeResponse ::
  (MonadError RemoteError m, Message a) =>
  ByteString ->
  m (ParsedMQTTResponse a)
decodeResponse bytes = do
  response <- unwrapResponse bytes
  for response \body -> do
    case fromByteString body of
      Left err -> throwError (parseErrorToRCE err)
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

-- Utilities
remoteError :: LText -> RemoteError
remoteError errMsg =
  RemoteError
    { remoteErrorErrorType = Enumerated $ Right RErrorMQTTFailure
    , remoteErrorMessage = errMsg
    , remoteErrorExtra = Nothing
    }

parseMessageOrError ::
  forall m a.
  (MonadError RemoteError m, Message a) =>
  LByteString ->
  m a
parseMessageOrError msg =
  case fromLazyByteString @a msg of
    Right a -> pure a
    Left err ->
      case fromLazyByteString @RemoteError msg of
        Left _ -> throwError err
        Right recvErr -> throwError recvErr

fromLazyByteString :: Message a => LByteString -> Either RemoteError a
fromLazyByteString msg =
  case fromByteString (toStrict msg) of
    Left parseErr -> Left $ parseErrorToRCE parseErr
    Right x -> Right x

-- Protobuf type conversions

toMetadataMap :: Proto.MetadataMap -> HL.MetadataMap
toMetadataMap (Proto.MetadataMap m) = HL.MetadataMap $ foldMap toMap m
  where
    toMap (MetadataMap_Entry k v) = M.singleton k (V.toList v)

fromMetadataMap :: HL.MetadataMap -> Proto.MetadataMap
fromMetadataMap (HL.MetadataMap m) = Proto.MetadataMap $ foldMap toVec (M.toAscList m)
  where
    toVec (k, v) = V.singleton $ MetadataMap_Entry k (V.fromList v)

toStatusCode :: Int32 -> Maybe StatusCode
toStatusCode = toEnumMaybe . fromIntegral
  where
    toEnumMaybe x =
      case unsafePerformIO $ try @ErrorCall (evaluateWHNF (toEnum x)) of
        Left _ -> Nothing
        Right sc -> Just sc

fromStatusCode :: StatusCode -> Int32
fromStatusCode = fromIntegral . fromEnum

toStatusDetails :: LText -> StatusDetails
toStatusDetails = StatusDetails . encodeUtf8

fromStatusDetails :: StatusDetails -> LText
fromStatusDetails = decodeUtf8 . unStatusDetails

-- Error conversions
toRemoteError :: ClientError -> RemoteError
toRemoteError (ClientErrorNoParse pe) = parseErrorToRCE pe
toRemoteError (ClientIOError ge) =
  case ge of
    GRPCIOCallError ce ->
      case ce of
        CallOk -> wrapPlainRCE RErrorIOGRPCCallOk
        CallError -> wrapPlainRCE RErrorIOGRPCCallError
        CallErrorNotOnServer -> wrapPlainRCE RErrorIOGRPCCallNotOnServer
        CallErrorNotOnClient -> wrapPlainRCE RErrorIOGRPCCallNotOnClient
        CallErrorAlreadyAccepted -> wrapPlainRCE RErrorIOGRPCCallAlreadyAccepted
        CallErrorAlreadyInvoked -> wrapPlainRCE RErrorIOGRPCCallAlreadyInvoked
        CallErrorNotInvoked -> wrapPlainRCE RErrorIOGRPCCallNotInvoked
        CallErrorAlreadyFinished -> wrapPlainRCE RErrorIOGRPCCallAlreadyFinished
        CallErrorTooManyOperations -> wrapPlainRCE RErrorIOGRPCCallTooManyOperations
        CallErrorInvalidFlags -> wrapPlainRCE RErrorIOGRPCCallInvalidFlags
        CallErrorInvalidMetadata -> wrapPlainRCE RErrorIOGRPCCallInvalidMetadata
        CallErrorInvalidMessage -> wrapPlainRCE RErrorIOGRPCCallInvalidMessage
        CallErrorNotServerCompletionQueue -> wrapPlainRCE RErrorIOGRPCCallNotServerCompletionQueue
        CallErrorBatchTooBig -> wrapPlainRCE RErrorIOGRPCCallBatchTooBig
        CallErrorPayloadTypeMismatch -> wrapPlainRCE RErrorIOGRPCCallPayloadTypeMismatch
        CallErrorCompletionQueueShutdown -> wrapPlainRCE RErrorIOGRPCCallCompletionQueueShutdown
    GRPCIOTimeout -> wrapPlainRCE RErrorIOGRPCTimeout
    GRPCIOShutdown -> wrapPlainRCE RErrorIOGRPCShutdown
    GRPCIOShutdownFailure -> wrapPlainRCE RErrorIOGRPCShutdownFailure
    GRPCIOUnknownError -> wrapPlainRCE RErrorUnknownError
    GRPCIOBadStatusCode sc sd -> wrapRCE RErrorIOGRPCBadStatusCode (fromStatusDetails sd) (Just (RemoteErrorExtraStatusCode (fromStatusCode sc)))
    GRPCIODecodeError s -> wrapRCE RErrorIOGRPCDecode (fromString s) Nothing
    GRPCIOInternalUnexpectedRecv s -> wrapRCE RErrorIOGRPCInternalUnexpectedRecv (fromString s) Nothing
    GRPCIOHandlerException s -> wrapRCE RErrorIOGRPCHandlerException (fromString s) Nothing
  where
    wrapRCE errType = RemoteError (Enumerated (Right errType))
    wrapPlainRCE errType = wrapRCE errType "" Nothing

fromRemoteError :: RemoteError -> MQTTResult streamtype response
fromRemoteError (RemoteError (Enumerated errType) errMsg errExtra) =
  case errType of
    Right RErrorIOGRPCCallOk -> wrapGRPCResult $ GRPCIOCallError CallOk
    Right RErrorIOGRPCCallError -> wrapGRPCResult $ GRPCIOCallError CallError
    Right RErrorIOGRPCCallNotOnServer -> wrapGRPCResult $ GRPCIOCallError CallErrorNotOnServer
    Right RErrorIOGRPCCallNotOnClient -> wrapGRPCResult $ GRPCIOCallError CallErrorNotOnClient
    Right RErrorIOGRPCCallAlreadyAccepted -> wrapGRPCResult $ GRPCIOCallError CallErrorAlreadyAccepted
    Right RErrorIOGRPCCallAlreadyInvoked -> wrapGRPCResult $ GRPCIOCallError CallErrorAlreadyInvoked
    Right RErrorIOGRPCCallNotInvoked -> wrapGRPCResult $ GRPCIOCallError CallErrorNotInvoked
    Right RErrorIOGRPCCallAlreadyFinished -> wrapGRPCResult $ GRPCIOCallError CallErrorAlreadyFinished
    Right RErrorIOGRPCCallTooManyOperations -> wrapGRPCResult $ GRPCIOCallError CallErrorTooManyOperations
    Right RErrorIOGRPCCallInvalidFlags -> wrapGRPCResult $ GRPCIOCallError CallErrorInvalidFlags
    Right RErrorIOGRPCCallInvalidMetadata -> wrapGRPCResult $ GRPCIOCallError CallErrorInvalidMetadata
    Right RErrorIOGRPCCallInvalidMessage -> wrapGRPCResult $ GRPCIOCallError CallErrorInvalidMessage
    Right RErrorIOGRPCCallNotServerCompletionQueue -> wrapGRPCResult $ GRPCIOCallError CallErrorNotServerCompletionQueue
    Right RErrorIOGRPCCallBatchTooBig -> wrapGRPCResult $ GRPCIOCallError CallErrorBatchTooBig
    Right RErrorIOGRPCCallPayloadTypeMismatch -> wrapGRPCResult $ GRPCIOCallError CallErrorPayloadTypeMismatch
    Right RErrorIOGRPCCallCompletionQueueShutdown -> wrapGRPCResult $ GRPCIOCallError CallErrorCompletionQueueShutdown
    Right RErrorIOGRPCTimeout -> wrapGRPCResult GRPCIOTimeout
    Right RErrorIOGRPCShutdown -> wrapGRPCResult GRPCIOShutdown
    Right RErrorIOGRPCShutdownFailure -> wrapGRPCResult GRPCIOShutdownFailure
    Right RErrorIOGRPCBadStatusCode
      | Just (RemoteErrorExtraStatusCode sc) <- errExtra
        , Just statusCode <- toStatusCode sc ->
        wrapGRPCResult $ GRPCIOBadStatusCode statusCode (toStatusDetails errMsg)
      | otherwise -> MQTTError "Failed to decode BadStatusCodeError"
    Right RErrorIOGRPCDecode -> wrapGRPCResult $ GRPCIODecodeError (toString errMsg)
    Right RErrorIOGRPCInternalUnexpectedRecv -> wrapGRPCResult $ GRPCIOInternalUnexpectedRecv (toString errMsg)
    Right RErrorIOGRPCHandlerException -> wrapGRPCResult $ GRPCIOHandlerException (toString errMsg)
    Right RErrorNoParseBinary -> wrapNoParseResult $ BinaryError errMsg
    Right RErrorNoParseWireType -> wrapNoParseResult $ WireTypeError errMsg
    Right RErrorNoParseEmbedded -> wrapNoParseResult $ EmbeddedError errMsg (handleEmbedded =<< errExtra)
    Right RErrorUnknownError -> MQTTError $ "Unknown error: " <> toStrict errMsg
    Right RErrorMQTTFailure -> MQTTError $ toStrict errMsg
    Left _ -> MQTTError $ "Unknown error: " <> toStrict errMsg
  where
    wrapGRPCResult = GRPCResult . ClientErrorResponse . ClientIOError
    wrapNoParseResult = GRPCResult . ClientErrorResponse . ClientErrorNoParse

handleEmbedded :: RemoteErrorExtra -> Maybe ParseError
handleEmbedded (RemoteErrorExtraEmbeddedError (RemoteError (Enumerated (Right errType)) errMsg errExtra)) =
  case errType of
    RErrorNoParseBinary -> Just $ BinaryError errMsg
    RErrorNoParseWireType -> Just $ WireTypeError errMsg
    RErrorNoParseEmbedded -> Just $ EmbeddedError errMsg (handleEmbedded =<< errExtra)
    _ -> Nothing
handleEmbedded _ = Nothing

parseErrorToRCE :: ParseError -> RemoteError
parseErrorToRCE (WireTypeError txt) = RemoteError (Enumerated (Right RErrorNoParseWireType)) txt Nothing
parseErrorToRCE (BinaryError txt) = RemoteError (Enumerated (Right RErrorNoParseBinary)) txt Nothing
parseErrorToRCE (EmbeddedError txt m_pe) =
  RemoteError
    (Enumerated (Right RErrorNoParseEmbedded))
    txt
    (RemoteErrorExtraEmbeddedError . parseErrorToRCE <$> m_pe)

toGRPCIOError :: RemoteError -> GRPCIOError
toGRPCIOError (RemoteError (Enumerated errType) errMsg errExtra) =
  case errType of
    Right RErrorIOGRPCCallOk -> GRPCIOCallError CallOk
    Right RErrorIOGRPCCallError -> GRPCIOCallError CallError
    Right RErrorIOGRPCCallNotOnServer -> GRPCIOCallError CallErrorNotOnServer
    Right RErrorIOGRPCCallNotOnClient -> GRPCIOCallError CallErrorNotOnClient
    Right RErrorIOGRPCCallAlreadyAccepted -> GRPCIOCallError CallErrorAlreadyAccepted
    Right RErrorIOGRPCCallAlreadyInvoked -> GRPCIOCallError CallErrorAlreadyInvoked
    Right RErrorIOGRPCCallNotInvoked -> GRPCIOCallError CallErrorNotInvoked
    Right RErrorIOGRPCCallAlreadyFinished -> GRPCIOCallError CallErrorAlreadyFinished
    Right RErrorIOGRPCCallTooManyOperations -> GRPCIOCallError CallErrorTooManyOperations
    Right RErrorIOGRPCCallInvalidFlags -> GRPCIOCallError CallErrorInvalidFlags
    Right RErrorIOGRPCCallInvalidMetadata -> GRPCIOCallError CallErrorInvalidMetadata
    Right RErrorIOGRPCCallInvalidMessage -> GRPCIOCallError CallErrorInvalidMessage
    Right RErrorIOGRPCCallNotServerCompletionQueue -> GRPCIOCallError CallErrorNotServerCompletionQueue
    Right RErrorIOGRPCCallBatchTooBig -> GRPCIOCallError CallErrorBatchTooBig
    Right RErrorIOGRPCCallPayloadTypeMismatch -> GRPCIOCallError CallErrorPayloadTypeMismatch
    Right RErrorIOGRPCCallCompletionQueueShutdown -> GRPCIOCallError CallErrorCompletionQueueShutdown
    Right RErrorIOGRPCTimeout -> GRPCIOTimeout
    Right RErrorIOGRPCShutdown -> GRPCIOShutdown
    Right RErrorIOGRPCShutdownFailure -> GRPCIOShutdownFailure
    Right RErrorIOGRPCBadStatusCode
      | Just (RemoteErrorExtraStatusCode sc) <- errExtra
        , Just statusCode <- toStatusCode sc ->
        GRPCIOBadStatusCode statusCode (toStatusDetails errMsg)
      | otherwise -> GRPCIODecodeError "Failed to decode BadStatusCodeError"
    Right RErrorIOGRPCDecode -> GRPCIODecodeError (toString errMsg)
    Right RErrorIOGRPCInternalUnexpectedRecv -> GRPCIOInternalUnexpectedRecv (toString errMsg)
    Right RErrorIOGRPCHandlerException -> GRPCIOHandlerException (toString errMsg)
    Right RErrorNoParseBinary -> GRPCIODecodeError (toString errMsg)
    Right RErrorNoParseWireType -> GRPCIODecodeError (toString errMsg)
    Right RErrorNoParseEmbedded -> GRPCIODecodeError (toString errMsg)
    Right RErrorUnknownError -> GRPCIOHandlerException ("Unknown error: " <> toString errMsg)
    Right RErrorMQTTFailure -> GRPCIOHandlerException ("Embeded MQTT error: " <> toString errMsg)
    Left _ -> GRPCIOHandlerException ("Unknown error: " <> toString errMsg)
