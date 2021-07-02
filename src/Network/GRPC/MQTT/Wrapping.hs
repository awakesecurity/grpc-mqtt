{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.MQTT.Wrapping where

import Relude

import Network.GRPC.MQTT.Types (
  ClientHandler (ClientServerStreamHandler, ClientUnaryHandler),
  MQTTResult (..),
  SomeClientHandler (..),
 )
import Network.MQTT.Topic (Topic)

import Proto.Mqtt as Proto (
  List (List, listValue),
  MetadataMap (MetadataMap),
  RCError (
    RCErrorIOGRPCBadStatusCode,
    RCErrorIOGRPCCallAlreadyAccepted,
    RCErrorIOGRPCCallAlreadyFinished,
    RCErrorIOGRPCCallAlreadyInvoked,
    RCErrorIOGRPCCallBatchTooBig,
    RCErrorIOGRPCCallCompletionQueueShutdown,
    RCErrorIOGRPCCallError,
    RCErrorIOGRPCCallInvalidFlags,
    RCErrorIOGRPCCallInvalidMessage,
    RCErrorIOGRPCCallInvalidMetadata,
    RCErrorIOGRPCCallNotInvoked,
    RCErrorIOGRPCCallNotOnClient,
    RCErrorIOGRPCCallNotOnServer,
    RCErrorIOGRPCCallNotServerCompletionQueue,
    RCErrorIOGRPCCallOk,
    RCErrorIOGRPCCallPayloadTypeMismatch,
    RCErrorIOGRPCCallTooManyOperations,
    RCErrorIOGRPCDecode,
    RCErrorIOGRPCHandlerException,
    RCErrorIOGRPCInternalUnexpectedRecv,
    RCErrorIOGRPCShutdown,
    RCErrorIOGRPCShutdownFailure,
    RCErrorIOGRPCTimeout,
    RCErrorMQTTFailure,
    RCErrorNoParseBinary,
    RCErrorNoParseEmbedded,
    RCErrorNoParseWireType,
    RCErrorUnknownError
  ),
  RemoteClientError (..),
  RemoteClientErrorExtra (..),
  SequencedResponse,
  StreamResponse (
    StreamResponse,
    streamResponseDetails,
    streamResponseMetamap,
    streamResponseResponseCode
  ),
  UnaryResponse (
    UnaryResponse,
    unaryResponseBody,
    unaryResponseDetails,
    unaryResponseInitMetamap,
    unaryResponseResponseCode,
    unaryResponseTrailMetamap
  ),
  WrappedMQTTRequest (WrappedMQTTRequest),
  WrappedStreamChunk (WrappedStreamChunk),
  WrappedStreamChunkOrError (
    WrappedStreamChunkOrErrorError,
    WrappedStreamChunkOrErrorValue
  ),
  WrappedStreamResponse (WrappedStreamResponse),
  WrappedStreamResponseOrError (
    WrappedStreamResponseOrErrorError,
    WrappedStreamResponseOrErrorResponse
  ),
  WrappedUnaryResponse (WrappedUnaryResponse),
  WrappedUnaryResponseOrErr (
    WrappedUnaryResponseOrErrError,
    WrappedUnaryResponseOrErrResponse
  ),
 )

import Control.Exception (ErrorCall, try)
import Data.ByteString.Base64 (decodeBase64, encodeBase64)
import qualified Data.Map as M
import Data.SortedList (fromSortedList, toSortedList)
import qualified Data.Vector as V
import GHC.IO.Unsafe (unsafePerformIO)
import Network.GRPC.HighLevel as HL (
  GRPCIOError (..),
  MetadataMap (MetadataMap),
  StatusCode,
  StatusDetails (..),
 )
import Network.GRPC.HighLevel.Client (
  ClientError (..),
  ClientRequest (ClientNormalRequest, ClientReaderRequest),
  ClientResult (
    ClientErrorResponse,
    ClientNormalResponse,
    ClientReaderResponse
  ),
  GRPCMethodType (Normal, ServerStreaming),
 )
import Network.GRPC.HighLevel.Server (toBS)
import Network.GRPC.Unsafe (CallError (..))
import Proto3.Suite (
  Enumerated (Enumerated),
  Message,
  fromByteString,
  toLazyByteString,
 )
import Proto3.Wire.Decode (ParseError (..))

-- Client Wrappers
wrapUnaryClientHandler ::
  (Message request, Message response) =>
  (ClientRequest 'Normal request response -> IO (ClientResult 'Normal response)) ->
  SomeClientHandler
wrapUnaryClientHandler handler =
  SomeClientHandler . ClientUnaryHandler $ \rawRequest timeout metadata ->
    case fromByteString rawRequest of
      Left err -> pure $ ClientErrorResponse (ClientErrorNoParse err)
      Right req -> handler (ClientNormalRequest req timeout metadata)

wrapServerStreamingClientHandler ::
  (Message request, Message response) =>
  (ClientRequest 'ServerStreaming request response -> IO (ClientResult 'ServerStreaming response)) ->
  SomeClientHandler
wrapServerStreamingClientHandler handler =
  SomeClientHandler . ClientServerStreamHandler $ \rawRequest timeout metadata recv ->
    case fromByteString rawRequest of
      Left err -> pure $ ClientErrorResponse (ClientErrorNoParse err)
      Right req -> handler (ClientReaderRequest req timeout metadata recv)

-- Requests
wrapRequest ::
  (Message request) =>
  Topic ->
  Int ->
  HL.MetadataMap ->
  request ->
  LByteString
wrapRequest responseTopic timeout reqMetadata request =
  toLazyByteString $
    WrappedMQTTRequest
      (toLazy responseTopic)
      (fromIntegral timeout)
      (Just $ fromMetadataMap reqMetadata)
      (toBS request)

-- Unary Wrappers
wrapUnaryResponse :: (Message response) => ClientResult 'Normal response -> LByteString
wrapUnaryResponse res =
  toLazyByteString . WrappedUnaryResponse . Just $
    case res of
      ClientNormalResponse rspBody initMD trailMD rspCode details ->
        WrappedUnaryResponseOrErrResponse $
          UnaryResponse
            (toBS rspBody)
            (Just $ fromMetadataMap initMD)
            (Just $ fromMetadataMap trailMD)
            (fromStatusCode rspCode)
            (fromStatusDetails details)
      ClientErrorResponse err ->
        WrappedUnaryResponseOrErrError $ toRemoteClientError err

unwrapUnaryResponse :: forall response. (Message response) => LByteString -> MQTTResult 'Normal response
unwrapUnaryResponse wrappedMessage = either id id parsedResult
 where
  parsedResult :: Either (MQTTResult 'Normal response) (MQTTResult 'Normal response)
  parsedResult = do
    WrappedUnaryResponse mResponse <- parseWithClientError (toStrict wrappedMessage)
    UnaryResponse{..} <- case mResponse of
      Nothing -> Left $ MQTTError "Empty response"
      Just (WrappedUnaryResponseOrErrError err) -> Left $ fromRemoteClientError err
      Just (WrappedUnaryResponseOrErrResponse resp) -> Right resp

    parsedResponseBody <- parseWithClientError unaryResponseBody

    statusCode <- case toStatusCode unaryResponseResponseCode of
      Nothing -> Left $ MQTTError ("Invalid reponse code: " <> show unaryResponseResponseCode)
      Just sc -> Right sc

    return $
      GRPCResult $
        ClientNormalResponse
          parsedResponseBody
          (maybe mempty toMetadataMap unaryResponseInitMetamap)
          (maybe mempty toMetadataMap unaryResponseTrailMetamap)
          statusCode
          (toStatusDetails unaryResponseDetails)

-- Streaming Wrappers
wrapStreamInitMetadata :: HL.MetadataMap -> LByteString
wrapStreamInitMetadata = toLazyByteString . fromMetadataMap

wrapStreamResponse :: ClientResult 'ServerStreaming response -> LByteString
wrapStreamResponse response =
  toLazyByteString . WrappedStreamResponse . Just $
    case response of
      ClientReaderResponse rspMetadata statusCode details ->
        WrappedStreamResponseOrErrorResponse $
          StreamResponse
            (Just $ fromMetadataMap rspMetadata)
            (fromStatusCode statusCode)
            (fromStatusDetails details)
      ClientErrorResponse ce ->
        WrappedStreamResponseOrErrorError $
          toRemoteClientError ce

unwrapStreamResponse :: forall response. LByteString -> MQTTResult 'ServerStreaming response
unwrapStreamResponse wrappedMessage = either id id parsedResult
 where
  parsedResult :: Either (MQTTResult 'ServerStreaming response) (MQTTResult 'ServerStreaming response)
  parsedResult = do
    WrappedStreamResponse mResponse <- parseWithClientError (toStrict wrappedMessage)
    StreamResponse{..} <- case mResponse of
      Nothing -> Left $ MQTTError "Empty response"
      Just (WrappedStreamResponseOrErrorError err) -> Left $ fromRemoteClientError err
      Just (WrappedStreamResponseOrErrorResponse resp) -> Right resp

    statusCode <- case toStatusCode streamResponseResponseCode of
      Nothing -> Left $ MQTTError ("Invalid reponse code: " <> show streamResponseResponseCode)
      Just sc -> Right sc

    return $
      GRPCResult $
        ClientReaderResponse
          (maybe mempty toMetadataMap streamResponseMetamap)
          statusCode
          (toStatusDetails streamResponseDetails)

wrapStreamChunk :: (Message response) => Maybe response -> LByteString
wrapStreamChunk chunk =
  toLazyByteString $
    WrappedStreamChunk
      (WrappedStreamChunkOrErrorValue . toBS <$> chunk)

unwrapStreamChunk :: (Message response) => Either RemoteClientError ByteString -> Either GRPCIOError (Maybe response)
unwrapStreamChunk (Left err) = Left $ toGRPCIOError err
unwrapStreamChunk (Right msg) =
  case fromByteString msg of
    Left err -> Left $ GRPCIODecodeError (displayException err)
    Right (WrappedStreamChunk chunk) ->
      case chunk of
        Nothing -> Right Nothing
        Just (WrappedStreamChunkOrErrorValue value) ->
          case fromByteString value of
            Left err -> Left $ GRPCIODecodeError (displayException err)
            Right rsp -> Right $ Just rsp
        Just (WrappedStreamChunkOrErrorError rcErr) -> Left $ toGRPCIOError rcErr

unwrapSequencedResponse :: ByteString -> Either RemoteClientError SequencedResponse
unwrapSequencedResponse bs =
  case fromByteString @SequencedResponse bs of
    Left parseErr -> do
      case fromByteString @RemoteClientError bs of
        Right rce -> Left rce
        _ -> Left (parseErrorToRCE parseErr)
    Right x -> Right x

-- Utility functions
wrapMQTTError :: LText -> LByteString
wrapMQTTError errMsg =
  toLazyByteString $
    RemoteClientError
      { remoteClientErrorErrorType = Enumerated $ Right RCErrorMQTTFailure
      , remoteClientErrorMessage = errMsg
      , remoteClientErrorExtra = Nothing
      }

parseWithClientError :: (Message a) => ByteString -> Either (MQTTResult streamtype response) a
parseWithClientError = first (GRPCResult . ClientErrorResponse . ClientErrorNoParse) . fromByteString

-- Protobuf type conversions

-- | NB: Destroys keys that fail to decode
toMetadataMap :: Proto.MetadataMap -> HL.MetadataMap
toMetadataMap (Proto.MetadataMap m) = HL.MetadataMap (convertVals <$> M.mapKeys convertKeys m)
 where
  convertVals = maybe [] (toSortedList . V.toList . listValue)
  convertKeys k =
    case decodeBase64 $ encodeUtf8 k of
      Left _err -> mempty
      Right k' -> k'

fromMetadataMap :: HL.MetadataMap -> Proto.MetadataMap
fromMetadataMap (HL.MetadataMap m) = Proto.MetadataMap (convertVals <$> M.mapKeys convertKeys m)
 where
  convertVals = Just . List . V.fromList . fromSortedList
  convertKeys = fromStrict . encodeBase64

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
toRemoteClientError :: ClientError -> RemoteClientError
toRemoteClientError (ClientErrorNoParse pe) = parseErrorToRCE pe
toRemoteClientError (ClientIOError ge) =
  case ge of
    GRPCIOCallError ce ->
      case ce of
        CallOk -> wrapPlainRCE RCErrorIOGRPCCallOk
        CallError -> wrapPlainRCE RCErrorIOGRPCCallError
        CallErrorNotOnServer -> wrapPlainRCE RCErrorIOGRPCCallNotOnServer
        CallErrorNotOnClient -> wrapPlainRCE RCErrorIOGRPCCallNotOnClient
        CallErrorAlreadyAccepted -> wrapPlainRCE RCErrorIOGRPCCallAlreadyAccepted
        CallErrorAlreadyInvoked -> wrapPlainRCE RCErrorIOGRPCCallAlreadyInvoked
        CallErrorNotInvoked -> wrapPlainRCE RCErrorIOGRPCCallNotInvoked
        CallErrorAlreadyFinished -> wrapPlainRCE RCErrorIOGRPCCallAlreadyFinished
        CallErrorTooManyOperations -> wrapPlainRCE RCErrorIOGRPCCallTooManyOperations
        CallErrorInvalidFlags -> wrapPlainRCE RCErrorIOGRPCCallInvalidFlags
        CallErrorInvalidMetadata -> wrapPlainRCE RCErrorIOGRPCCallInvalidMetadata
        CallErrorInvalidMessage -> wrapPlainRCE RCErrorIOGRPCCallInvalidMessage
        CallErrorNotServerCompletionQueue -> wrapPlainRCE RCErrorIOGRPCCallNotServerCompletionQueue
        CallErrorBatchTooBig -> wrapPlainRCE RCErrorIOGRPCCallBatchTooBig
        CallErrorPayloadTypeMismatch -> wrapPlainRCE RCErrorIOGRPCCallPayloadTypeMismatch
        CallErrorCompletionQueueShutdown -> wrapPlainRCE RCErrorIOGRPCCallCompletionQueueShutdown
    GRPCIOTimeout -> wrapPlainRCE RCErrorIOGRPCTimeout
    GRPCIOShutdown -> wrapPlainRCE RCErrorIOGRPCShutdown
    GRPCIOShutdownFailure -> wrapPlainRCE RCErrorIOGRPCShutdownFailure
    GRPCIOUnknownError -> wrapPlainRCE RCErrorUnknownError
    GRPCIOBadStatusCode sc sd -> wrapRCE RCErrorIOGRPCBadStatusCode (fromStatusDetails sd) (Just (RemoteClientErrorExtraStatusCode (fromStatusCode sc)))
    GRPCIODecodeError s -> wrapRCE RCErrorIOGRPCDecode (fromString s) Nothing
    GRPCIOInternalUnexpectedRecv s -> wrapRCE RCErrorIOGRPCInternalUnexpectedRecv (fromString s) Nothing
    GRPCIOHandlerException s -> wrapRCE RCErrorIOGRPCHandlerException (fromString s) Nothing
 where
  wrapRCE errType = RemoteClientError (Enumerated (Right errType))
  wrapPlainRCE errType = wrapRCE errType "" Nothing

fromRemoteClientError :: RemoteClientError -> MQTTResult streamtype response
fromRemoteClientError (RemoteClientError (Enumerated errType) errMsg errExtra) =
  case errType of
    Right RCErrorIOGRPCCallOk -> wrapGRPCResult $ GRPCIOCallError CallOk
    Right RCErrorIOGRPCCallError -> wrapGRPCResult $ GRPCIOCallError CallError
    Right RCErrorIOGRPCCallNotOnServer -> wrapGRPCResult $ GRPCIOCallError CallErrorNotOnServer
    Right RCErrorIOGRPCCallNotOnClient -> wrapGRPCResult $ GRPCIOCallError CallErrorNotOnClient
    Right RCErrorIOGRPCCallAlreadyAccepted -> wrapGRPCResult $ GRPCIOCallError CallErrorAlreadyAccepted
    Right RCErrorIOGRPCCallAlreadyInvoked -> wrapGRPCResult $ GRPCIOCallError CallErrorAlreadyInvoked
    Right RCErrorIOGRPCCallNotInvoked -> wrapGRPCResult $ GRPCIOCallError CallErrorNotInvoked
    Right RCErrorIOGRPCCallAlreadyFinished -> wrapGRPCResult $ GRPCIOCallError CallErrorAlreadyFinished
    Right RCErrorIOGRPCCallTooManyOperations -> wrapGRPCResult $ GRPCIOCallError CallErrorTooManyOperations
    Right RCErrorIOGRPCCallInvalidFlags -> wrapGRPCResult $ GRPCIOCallError CallErrorInvalidFlags
    Right RCErrorIOGRPCCallInvalidMetadata -> wrapGRPCResult $ GRPCIOCallError CallErrorInvalidMetadata
    Right RCErrorIOGRPCCallInvalidMessage -> wrapGRPCResult $ GRPCIOCallError CallErrorInvalidMessage
    Right RCErrorIOGRPCCallNotServerCompletionQueue -> wrapGRPCResult $ GRPCIOCallError CallErrorNotServerCompletionQueue
    Right RCErrorIOGRPCCallBatchTooBig -> wrapGRPCResult $ GRPCIOCallError CallErrorBatchTooBig
    Right RCErrorIOGRPCCallPayloadTypeMismatch -> wrapGRPCResult $ GRPCIOCallError CallErrorPayloadTypeMismatch
    Right RCErrorIOGRPCCallCompletionQueueShutdown -> wrapGRPCResult $ GRPCIOCallError CallErrorCompletionQueueShutdown
    Right RCErrorIOGRPCTimeout -> wrapGRPCResult GRPCIOTimeout
    Right RCErrorIOGRPCShutdown -> wrapGRPCResult GRPCIOShutdown
    Right RCErrorIOGRPCShutdownFailure -> wrapGRPCResult GRPCIOShutdownFailure
    Right RCErrorIOGRPCBadStatusCode
      | Just (RemoteClientErrorExtraStatusCode sc) <- errExtra
        , Just statusCode <- toStatusCode sc ->
        wrapGRPCResult $ GRPCIOBadStatusCode statusCode (toStatusDetails errMsg)
      | otherwise -> MQTTError "Failed to decode BadStatusCodeError"
    Right RCErrorIOGRPCDecode -> wrapGRPCResult $ GRPCIODecodeError (toString errMsg)
    Right RCErrorIOGRPCInternalUnexpectedRecv -> wrapGRPCResult $ GRPCIOInternalUnexpectedRecv (toString errMsg)
    Right RCErrorIOGRPCHandlerException -> wrapGRPCResult $ GRPCIOHandlerException (toString errMsg)
    Right RCErrorNoParseBinary -> wrapNoParseResult $ BinaryError errMsg
    Right RCErrorNoParseWireType -> wrapNoParseResult $ WireTypeError errMsg
    Right RCErrorNoParseEmbedded -> wrapNoParseResult $ EmbeddedError errMsg (handleEmbedded =<< errExtra)
    Right RCErrorUnknownError -> MQTTError $ "Unknown error: " <> toStrict errMsg
    Right RCErrorMQTTFailure -> MQTTError $ toStrict errMsg
    Left _ -> MQTTError $ "Unknown error: " <> toStrict errMsg
 where
  wrapGRPCResult = GRPCResult . ClientErrorResponse . ClientIOError
  wrapNoParseResult = GRPCResult . ClientErrorResponse . ClientErrorNoParse

handleEmbedded :: RemoteClientErrorExtra -> Maybe ParseError
handleEmbedded (RemoteClientErrorExtraEmbeddedError (RemoteClientError (Enumerated (Right errType)) errMsg errExtra)) =
  case errType of
    RCErrorNoParseBinary -> Just $ BinaryError errMsg
    RCErrorNoParseWireType -> Just $ WireTypeError errMsg
    RCErrorNoParseEmbedded -> Just $ EmbeddedError errMsg (handleEmbedded =<< errExtra)
    _ -> Nothing
handleEmbedded _ = Nothing

parseErrorToRCE :: ParseError -> RemoteClientError
parseErrorToRCE (WireTypeError txt) = RemoteClientError (Enumerated (Right RCErrorNoParseWireType)) txt Nothing
parseErrorToRCE (BinaryError txt) = RemoteClientError (Enumerated (Right RCErrorNoParseBinary)) txt Nothing
parseErrorToRCE (EmbeddedError txt m_pe) =
  RemoteClientError
    (Enumerated (Right RCErrorNoParseEmbedded))
    txt
    (RemoteClientErrorExtraEmbeddedError . parseErrorToRCE <$> m_pe)

toGRPCIOError :: RemoteClientError -> GRPCIOError
toGRPCIOError (RemoteClientError (Enumerated errType) errMsg errExtra) =
  case errType of
    Right RCErrorIOGRPCCallOk -> GRPCIOCallError CallOk
    Right RCErrorIOGRPCCallError -> GRPCIOCallError CallError
    Right RCErrorIOGRPCCallNotOnServer -> GRPCIOCallError CallErrorNotOnServer
    Right RCErrorIOGRPCCallNotOnClient -> GRPCIOCallError CallErrorNotOnClient
    Right RCErrorIOGRPCCallAlreadyAccepted -> GRPCIOCallError CallErrorAlreadyAccepted
    Right RCErrorIOGRPCCallAlreadyInvoked -> GRPCIOCallError CallErrorAlreadyInvoked
    Right RCErrorIOGRPCCallNotInvoked -> GRPCIOCallError CallErrorNotInvoked
    Right RCErrorIOGRPCCallAlreadyFinished -> GRPCIOCallError CallErrorAlreadyFinished
    Right RCErrorIOGRPCCallTooManyOperations -> GRPCIOCallError CallErrorTooManyOperations
    Right RCErrorIOGRPCCallInvalidFlags -> GRPCIOCallError CallErrorInvalidFlags
    Right RCErrorIOGRPCCallInvalidMetadata -> GRPCIOCallError CallErrorInvalidMetadata
    Right RCErrorIOGRPCCallInvalidMessage -> GRPCIOCallError CallErrorInvalidMessage
    Right RCErrorIOGRPCCallNotServerCompletionQueue -> GRPCIOCallError CallErrorNotServerCompletionQueue
    Right RCErrorIOGRPCCallBatchTooBig -> GRPCIOCallError CallErrorBatchTooBig
    Right RCErrorIOGRPCCallPayloadTypeMismatch -> GRPCIOCallError CallErrorPayloadTypeMismatch
    Right RCErrorIOGRPCCallCompletionQueueShutdown -> GRPCIOCallError CallErrorCompletionQueueShutdown
    Right RCErrorIOGRPCTimeout -> GRPCIOTimeout
    Right RCErrorIOGRPCShutdown -> GRPCIOShutdown
    Right RCErrorIOGRPCShutdownFailure -> GRPCIOShutdownFailure
    Right RCErrorIOGRPCBadStatusCode
      | Just (RemoteClientErrorExtraStatusCode sc) <- errExtra
        , Just statusCode <- toStatusCode sc ->
        GRPCIOBadStatusCode statusCode (toStatusDetails errMsg)
      | otherwise -> GRPCIODecodeError "Failed to decode BadStatusCodeError"
    Right RCErrorIOGRPCDecode -> GRPCIODecodeError (toString errMsg)
    Right RCErrorIOGRPCInternalUnexpectedRecv -> GRPCIOInternalUnexpectedRecv (toString errMsg)
    Right RCErrorIOGRPCHandlerException -> GRPCIOHandlerException (toString errMsg)
    Right RCErrorNoParseBinary -> GRPCIODecodeError (toString errMsg)
    Right RCErrorNoParseWireType -> GRPCIODecodeError (toString errMsg)
    Right RCErrorNoParseEmbedded -> GRPCIODecodeError (toString errMsg)
    Right RCErrorUnknownError -> GRPCIOHandlerException ("Unknown error: " <> toString errMsg)
    Right RCErrorMQTTFailure -> GRPCIOHandlerException ("Embeded MQTT error: " <> toString errMsg)
    Left _ -> GRPCIOHandlerException ("Unknown error: " <> toString errMsg)
