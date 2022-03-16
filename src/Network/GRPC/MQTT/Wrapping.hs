-- Copright (c) 2021 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RecordWildCards #-}
-- Disable import lists in order to avoid having to enumerate the constructors
-- for error handler types exported by 'grpc-haskell'.
{-# OPTIONS_GHC -Wno-missing-import-lists #-}

-- |
module Network.GRPC.MQTT.Wrapping
  ( fromRemoteError,
    parseMessageOrError,
    remoteError,
    toGRPCIOError,
    wrapResponse,
    unwrapUnaryResponse,
    unwrapClientStreamResponse,
    unwrapServerStreamResponse,
    wrapUnaryClientHandler,
    wrapClientStreamingClientHandler,
    wrapServerStreamingClientHandler,
    wrapBiDiStreamingClientHandler,
    unwrapBiDiStreamResponse,
  )
where

import Control.Exception (ErrorCall, try)
import GHC.IO.Unsafe (unsafePerformIO)
import Network.GRPC.HighLevel as HL
  ( GRPCIOError (..),
    MetadataMap,
    StatusCode,
    StatusDetails (StatusDetails, unStatusDetails),
  )
import Data.Text.Lazy qualified as Text.Lazy
import Network.GRPC.HighLevel.Server (toBS)
import Network.GRPC.Unsafe (CallError (..))
import Proto3.Suite (Enumerated (Enumerated), Message, fromByteString)
import Proto3.Wire.Decode (ParseError (..))
import Network.GRPC.HighLevel.Client
  ( ClientError (..),
    ClientRequest (..),
    ClientResult (..),
    GRPCMethodType (..),
  )

import Network.GRPC.MQTT.Wrap.Response
  ( Response(Response),
    rspCode,
    rspBody,
    rspDetails,
    rspInitMetamap,
    rspTrailMetamap,
  )
import Network.GRPC.MQTT.Types
  ( Batched,
    ClientHandler (..),
    MQTTResult (GRPCResult, MQTTError),
  )
import Network.GRPC.MQTT.Wrap
  ( Wrap
  , fromLazyByteString
  , parseErrorToRCE
  , pattern WrapError, pattern WrapRight, unwrap )
import Proto.Mqtt
  ( RError (..),
    RemoteError (..),
    RemoteErrorExtra (..),
  )

--------------------------------------------------------------------------------

type Handler :: Type -> Type -> Constraint
type Handler rqt rsp = (Message rqt, Message rsp)

-- Client Handler Wrappers
wrapUnaryClientHandler ::
  Handler rqt rsp =>
  (ClientRequest 'Normal rqt rsp -> IO (ClientResult 'Normal rsp)) ->
  ClientHandler
wrapUnaryClientHandler handler =
  ClientUnaryHandler $ \rawRqt timeout metadata ->
    case fromByteString rawRqt of
      Left err -> pure $ ClientErrorResponse (ClientErrorNoParse err)
      Right req -> handler (ClientNormalRequest req timeout metadata)

wrapServerStreamingClientHandler ::
  Handler rqt rsp =>
  Batched ->
  (ClientRequest 'ServerStreaming rqt rsp -> IO (ClientResult 'ServerStreaming rsp)) ->
  ClientHandler
wrapServerStreamingClientHandler useBatchedStream handler =
  ClientServerStreamHandler useBatchedStream $ \rawRqt timeout metadata recv ->
    case fromByteString rawRqt of
      Left err -> pure $ ClientErrorResponse (ClientErrorNoParse err)
      Right req -> handler (ClientReaderRequest req timeout metadata recv)

wrapClientStreamingClientHandler ::
  Handler rqt rsp =>
  (ClientRequest 'ClientStreaming rqt rsp -> IO (ClientResult 'ClientStreaming rsp)) ->
  ClientHandler
wrapClientStreamingClientHandler handler =
  ClientClientStreamHandler $ \timeout metadata send -> do
    handler (ClientWriterRequest timeout metadata send)

wrapBiDiStreamingClientHandler ::
  Handler rqt rsp =>
  Batched ->
  (ClientRequest 'BiDiStreaming rqt rsp -> IO (ClientResult 'BiDiStreaming rsp)) ->
  ClientHandler
wrapBiDiStreamingClientHandler useBatchedStream handler =
  ClientBiDiStreamHandler useBatchedStream $ \timeout metadata bidi -> do
    handler (ClientBiDiRequest timeout metadata bidi)

-- Responses
wrapResponse :: Message rsp => ClientResult streamType rsp -> Wrap Response
wrapResponse = \case
    ClientErrorResponse err -> WrapError (toRemoteError err)
    ClientNormalResponse body initMD trailMD status details ->
      WrapRight $ Response
        (toBS body)
        initMD
        trailMD
        (fromStatusCode status)
        (Text.Lazy.toStrict $ fromStatusDetails details)
    ClientWriterResponse body initMD trailMD status details ->
      WrapRight $ Response
        (maybe mempty toBS body)
        initMD
        trailMD
        (fromStatusCode status)
        (Text.Lazy.toStrict $ fromStatusDetails details)
    ClientReaderResponse metadata status details ->
      WrapRight $ Response
        mempty
        mempty
        metadata
        (fromStatusCode status)
        (Text.Lazy.toStrict $ fromStatusDetails details)
    ClientBiDiResponse metadata status details ->
      WrapRight $ Response
        mempty
        mempty
        metadata
        (fromStatusCode status)
        (Text.Lazy.toStrict $ fromStatusDetails details)

data ParsedResponse rsp = ParsedResponse
  { rspBody :: rsp
  , initMetadata :: HL.MetadataMap
  , trailMetadata :: HL.MetadataMap
  , statusCode :: StatusCode
  , statusDetails :: StatusDetails
  }

unwrapResponse :: Message rsp => LByteString -> Wrap (ParsedResponse rsp)
unwrapResponse bytes = do
  Response {..} <- fromLazyByteString bytes

  body <- handleResponseBody rspBody
  status <- handleStatusCode rspCode

  let statusDetails = toStatusDetails (Text.Lazy.fromStrict rspDetails)

  pure (ParsedResponse body rspInitMetamap rspTrailMetamap status statusDetails)
  where
    handleResponseBody :: Message rsp => ByteString -> Wrap rsp
    handleResponseBody rspbytes =
      case fromByteString rspbytes of
        Left perr -> WrapError (parseErrorToRCE perr)
        Right rsp -> pure rsp

    handleStatusCode :: Int32 -> Wrap StatusCode
    handleStatusCode statusM =
      case toStatusCode statusM of
        Nothing -> WrapError (remoteError $ "Invalid response code (" <> show statusM <> ")")
        Just code -> WrapRight code

unwrapUnaryResponse :: forall rsp. Message rsp => LByteString -> Wrap (MQTTResult 'Normal rsp)
unwrapUnaryResponse wrappedMessage = toNormalResult <$> unwrapResponse wrappedMessage
  where
    toNormalResult :: ParsedResponse rsp -> MQTTResult 'Normal rsp
    toNormalResult ParsedResponse{..} =
      GRPCResult (ClientNormalResponse rspBody initMetadata trailMetadata statusCode statusDetails)

unwrapClientStreamResponse ::
  forall rsp.
  Message rsp =>
  LByteString ->
  Wrap (MQTTResult 'ClientStreaming rsp)
unwrapClientStreamResponse wrappedMessage = toClientStreamResult <$> unwrapResponse wrappedMessage
  where
    toClientStreamResult :: ParsedResponse rsp -> MQTTResult 'ClientStreaming rsp
    toClientStreamResult ParsedResponse{..} =
      GRPCResult (ClientWriterResponse (Just rspBody) initMetadata trailMetadata statusCode statusDetails)

unwrapServerStreamResponse :: forall rsp. (Message rsp) => LByteString -> Wrap (MQTTResult 'ServerStreaming rsp)
unwrapServerStreamResponse wrappedMessage = toServerStreamResult <$> unwrapResponse wrappedMessage
  where
    toServerStreamResult :: ParsedResponse rsp -> MQTTResult 'ServerStreaming rsp
    toServerStreamResult ParsedResponse{..} =
      GRPCResult $ ClientReaderResponse trailMetadata statusCode statusDetails

unwrapBiDiStreamResponse :: forall rsp. (Message rsp) => LByteString -> Wrap (MQTTResult 'BiDiStreaming rsp)
unwrapBiDiStreamResponse wrappedMessage = toBiDiStreamResult <$> unwrapResponse wrappedMessage
  where
    toBiDiStreamResult :: ParsedResponse rsp -> MQTTResult 'BiDiStreaming rsp
    toBiDiStreamResult ParsedResponse {..} =
      GRPCResult $ ClientBiDiResponse trailMetadata statusCode statusDetails

-- Utilities
remoteError :: LText -> RemoteError
remoteError errMsg = RemoteError (Enumerated (Right RErrorMQTTFailure)) errMsg Nothing

-- FIXME: duplicated 'fromLazyByteString'?
parseMessageOrError :: Message a => LByteString -> Either RemoteError a
parseMessageOrError = unwrap . fromLazyByteString

-- Protobuf type conversions

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

fromRemoteError :: RemoteError -> MQTTResult streamtype rsp
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
