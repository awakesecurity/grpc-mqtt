{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | Setup for the grpc-haskell service used by the testing suite.
module Test.Proto.Service
  ( -- * TODO
    newTestService,
  )
where

---------------------------------------------------------------------------------

import Control.Concurrent.Async qualified as Async

import Control.Monad (forM, forM_)

import Data.Foldable (for_)
import Data.Function (fix)
import Data.Functor (($>))
import Data.Int (Int32)
import Data.Maybe (isJust)

import Data.Either (fromRight)
import Data.String (fromString)
import Data.Text.Lazy qualified as Lazy (Text)
import Data.Text.Lazy qualified as Lazy.Text
import Data.ByteString.Lazy qualified as Lazy.ByteString

import Network.GRPC.HighLevel
  ( MetadataMap,
    StatusCode (StatusOk, StatusUnknown),
    StatusDetails,
  )
import Network.GRPC.HighLevel.Client
  ( ClientConfig
      ( ClientConfig,
        clientArgs,
        clientAuthority,
        clientSSLConfig,
        clientServerHost,
        clientServerPort
      ),
    Port,
  )
import Network.GRPC.HighLevel.Generated
  ( GRPCMethodType (BiDiStreaming, ClientStreaming, Normal, ServerStreaming),
    ServiceOptions,
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

import Proto3.Suite
import Turtle (sleep)

---------------------------------------------------------------------------------

import Proto.Message
  ( BiDiRequestReply,
    OneInt,
    StreamReply,
    StreamRequest,
    TwoInts,
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
        { Proto.testServiceNormalCall = handleClientNormal
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
    let greet = name <> Lazy.Text.pack (show i)
    _ <- ssend (Message.StreamReply greet)
    sleep 0.1

  pure (ServerWriterResponse metadata StatusOk details)
  where
    metadata :: MetadataMap
    metadata = [] -- [("server_writer_key", "server_writer_metadata")]

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
