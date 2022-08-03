{-# LANGUAGE CPP #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TypeApplications #-}

-- | Setup for the grpc-haskell service used by the testing suite.
module Test.Proto.Service
  ( newTestService,
  )
where

---------------------------------------------------------------------------------

import Data.ByteString qualified as ByteString 

import Network.GRPC.HighLevel
  ( MetadataMap,
    StatusCode (StatusOk, StatusUnknown),
    StatusDetails,
  )
import Network.GRPC.HighLevel.Generated
  ( GRPCMethodType (BiDiStreaming, ClientStreaming, Normal, ServerStreaming),
    ServiceOptions, ServerCall(..),
  )
import Network.GRPC.HighLevel.Server
  ( ServerRequest
      ( ServerBiDiRequest,
        ServerNormalRequest,
        ServerReaderRequest,
        ServerWriterRequest
      ),
    ServerResponse
      ( ServerBiDiResponse,
        ServerNormalResponse,
        ServerReaderResponse,
        ServerWriterResponse
      ),
  )

import Turtle (sleep)

import Relude

---------------------------------------------------------------------------------

import Proto.Message
  ( BiDiRequestReply,
    OneInt,
    StreamReply,
    StreamRequest,
  )
import Proto.Message qualified as Message
import Proto.Service (TestService)
import Proto.Service qualified as Proto

---------------------------------------------------------------------------------

newTestService :: ServiceOptions -> IO ()
newTestService = Proto.testServiceServer testServiceHandlers
  where
    testServiceHandlers :: TestService ServerRequest ServerResponse
    testServiceHandlers =
      Proto.TestService
        {
#if MIN_VERSION_proto3_suite(0,4,3)
          Proto.testServicecallLongBytes = handleClientLongBytes
        , Proto.testServicenormalCall = handleClientNormal
#else
          Proto.testServiceCallLongBytes
        , Proto.testServiceNormalCall = handleClientNormal
#endif
        , Proto.testServiceClientStreamCall = handleClientStream
        , Proto.testServiceServerStreamCall = handleServerStream
        , Proto.testServiceBiDiStreamCall = handleBiDi
        -- Batched Streaming Calls
        , Proto.testServiceBatchClientStreamCall = handleClientStream
        , Proto.testServiceBatchServerStreamCall = handleServerStream
        , Proto.testServiceBatchBiDiStreamCall = handleBiDi
        }

---------------------------------------------------------------------------------
--
-- Test service handlers
--

type Handler s rqt rsp = ServerRequest s rqt rsp -> IO (ServerResponse s rsp)

handleClientLongBytes :: Handler 'Normal Message.OneInt Message.BytesResponse 
handleClientLongBytes (ServerNormalRequest ServerCall{metadata=mm} (Message.OneInt x)) =
  let response :: Message.BytesResponse
      response = Message.BytesResponse (ByteString.replicate (1_000_000 * fromIntegral x) 1)

      metadata :: MetadataMap
      metadata = mm<>[("normal_client_key", "normal_client_metadata")]

      details :: StatusDetails
      details = fromString ("client normal: added ints " ++ show x)
   in return (ServerNormalResponse response metadata StatusOk details)

handleClientNormal :: Handler 'Normal Message.TwoInts Message.OneInt
handleClientNormal (ServerNormalRequest _ (Message.TwoInts x y)) =
  let response :: Message.OneInt
      response = Message.OneInt (x + y)

      metadata :: MetadataMap
      metadata = [("normal_client_key", "normal_client_metadata")]

      details :: StatusDetails
      details = fromString ("client normal: added ints " ++ show x ++ " & " ++ show y)
   in return (ServerNormalResponse response metadata StatusOk details)

handleClientStream :: Handler 'ClientStreaming Message.OneInt Message.OneInt
handleClientStream (ServerReaderRequest _ recv) = loop 0
  where
    loop :: Int32 -> IO (ServerResponse 'ClientStreaming OneInt)
    loop ! i =
      recv >>= \case
        Left err -> return (newReaderRsp Nothing (show err))
        Right Nothing -> do
          let response :: Maybe OneInt
              response = Just (Message.OneInt i)
           in return (newReaderRsp response "")
        Right (Just (Message.OneInt x)) -> loop (i + x)

    newReaderRsp :: Maybe OneInt -> String -> ServerResponse 'ClientStreaming OneInt
    newReaderRsp xs
      | isJust xs = ServerReaderResponse xs [] StatusOk . fromString
      | otherwise = ServerReaderResponse xs [] StatusUnknown . fromString

handleServerStream :: Handler 'ServerStreaming StreamRequest StreamReply
handleServerStream (ServerWriterRequest _ (Message.StreamRequest name n) ssend) = do
  forM_ @[] [1 .. n] \i -> do
    let greet = name <> show i
    _ <- ssend (Message.StreamReply greet)
    sleep 0.1

  pure (ServerWriterResponse metadata StatusOk details)
  where
    metadata :: MetadataMap
    metadata = [("server_writer_key", "server_writer_metadata")]

    details :: StatusDetails
    details = fromString ("stream is done" ++ show name)

handleBiDi :: Handler 'BiDiStreaming BiDiRequestReply BiDiRequestReply
handleBiDi (ServerBiDiRequest _ recv send) = fix \go ->
  recv >>= \case
    Left e -> fail $ "helloBi recv error: " ++ show e
    Right Nothing -> return $ ServerBiDiResponse mempty StatusOk (fromString "helloBi details")
    Right (Just rqt) -> do
      send rqt >>= \case
        Left e -> fail $ "helloBi send error: " ++ show e
        _ -> go
