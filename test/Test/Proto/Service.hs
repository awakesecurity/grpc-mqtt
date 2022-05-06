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

import Data.Foldable (for_)
import Data.Function (fix)
import Data.Functor (($>))
import Data.Int (Int32)
import Data.Maybe (isJust)

import Data.String (fromString)
import Data.Text.Lazy qualified as Lazy (Text)
import Data.Text.Lazy qualified as Lazy.Text

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

import Turtle (sleep)

---------------------------------------------------------------------------------

import Proto.Message (BiRqtRpy, OneInt, SSRpy, SSRqt, TwoInts)
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
        { Proto.testServiceNormal = handleClientNormal
        , Proto.testServiceClientStream = handleClientStream
        , Proto.testServiceServerStream = handleServerStream
        , Proto.testServiceBiDi = handleBiDi
        }

---------------------------------------------------------------------------------
--
-- Test service handlers
--

type Handler s rqt rsp = ServerRequest s rqt rsp -> IO (ServerResponse s rsp)

handleClientNormal :: Handler 'Normal TwoInts OneInt
handleClientNormal (ServerNormalRequest _ (Message.TwoInts x y)) =
  let response :: Message.OneInt
      response = Message.OneInt (x + y)

      metadata :: MetadataMap
      metadata = [("normal_client_key", "normal_client_metadata")]

      details :: StatusDetails
      details = fromString ("client normal: added ints " ++ show x ++ " & " ++ show y)
   in return (ServerNormalResponse response metadata StatusOk details)

handleClientStream :: Handler 'ClientStreaming OneInt OneInt
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

handleServerStream :: Handler 'ServerStreaming SSRqt SSRpy
handleServerStream (ServerWriterRequest _ (Message.SSRqt name n) ssend) = do
  for_ @[] [1 .. n] \i -> do
    let greeting :: Lazy.Text
        greeting = "Hello, " <> name <> " - " <> Lazy.Text.pack (show i)
     in ssend (Message.SSRpy greeting) $> ()
    sleep 0.1

  let metadata :: MetadataMap
      metadata = [("server_writer_key", "server_writer_metadata")]

      details :: StatusDetails
      details = fromString ("server writer: greeted " ++ show name)
   in return (ServerWriterResponse metadata StatusOk details)

handleBiDi :: Handler 'BiDiStreaming BiRqtRpy BiRqtRpy
handleBiDi (ServerBiDiRequest _ recv send) = fix \go ->
  recv >>= \case
    Left e -> fail $ "helloBi recv error: " ++ show e
    Right Nothing -> return $ ServerBiDiResponse mempty StatusOk (fromString "helloBi details")
    Right (Just rqt) -> do
      send rqt >>= \case
        Left e -> fail $ "helloBi send error: " ++ show e
        _ -> go
