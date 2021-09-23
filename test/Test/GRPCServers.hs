{-
  Copyright (c) 2021 Arista Networks, Inc.
  Use of this source code is governed by the Apache License 2.0
  that can be found in the COPYING file.
-}
{-# LANGUAGE OverloadedLists #-}

module Test.GRPCServers where

import Relude

import Proto.Test
  ( AddHello (..),
    BiRqtRpy,
    MultGoodbye (..),
    OneInt (OneInt),
    SSRpy (SSRpy),
    SSRqt (SSRqt),
    TwoInts (TwoInts),
    addHelloServer,
    multGoodbyeServer,
  )

import Network.GRPC.HighLevel
  ( ServiceOptions,
    StatusCode (StatusOk),
    StatusDetails (..),
  )
import Network.GRPC.HighLevel.Generated
  ( GRPCMethodType (BiDiStreaming, ClientStreaming, Normal, ServerStreaming),
    ServerRequest (ServerBiDiRequest, ServerNormalRequest, ServerReaderRequest, ServerWriterRequest),
    ServerResponse (ServerBiDiResponse, ServerNormalResponse, ServerReaderResponse, ServerWriterResponse),
    StatusCode (StatusUnknown),
  )
import Turtle (sleep)

addHelloService :: ServiceOptions -> IO ()
addHelloService = addHelloServer addHelloHandlers

addHelloHandlers :: AddHello ServerRequest ServerResponse
addHelloHandlers =
  AddHello
    { addHelloAdd = addHandler
    , addHelloHelloSS = helloSSHandler
    , addHelloRunningSum = runningSumHandler
    , addHelloHelloBi = helloBiHandler
    , addHelloHelloSSBatch = helloSSHandler
    , addHelloRunningSumBatch = runningSumHandler
    , addHelloHelloBiBatch = helloBiHandler
    }

addHandler ::
  ServerRequest 'Normal TwoInts OneInt ->
  IO (ServerResponse 'Normal OneInt)
addHandler (ServerNormalRequest _metadata (TwoInts x y)) = do
  let answer = OneInt (x + y)
  return
    ( ServerNormalResponse
        answer
        [("metadata_key_one", "metadata_add")]
        StatusOk
        "addition is easy!"
    )

helloSSHandler :: ServerRequest 'ServerStreaming SSRqt SSRpy -> IO (ServerResponse 'ServerStreaming SSRpy)
helloSSHandler (ServerWriterRequest _metadata (SSRqt name numReplies) ssend) = do
  let range :: [Int]
      range = [1 .. fromIntegral numReplies]

  forM_ range $ \n -> do
    _ <- ssend $ greeting n
    sleep 0.1

  return $ ServerWriterResponse [("metadata_field", "metadata_helloSS")] StatusOk "Stream is done"
  where
    greeting :: Int -> SSRpy
    greeting i = SSRpy $ "Hello, " <> name <> " - " <> show i

infiniteHelloSSHandler :: ServerRequest 'ServerStreaming SSRqt SSRpy -> IO (ServerResponse 'ServerStreaming SSRpy)
infiniteHelloSSHandler (ServerWriterRequest _metadata (SSRqt name _) ssend) = do
  let range :: [Int]
      range = [1 ..]

  forM_ range $ \n -> do
    _ <- ssend $ greeting n
    sleep 0.1

  return $ ServerWriterResponse [("metadata_field", "metadata_infiniteHelloSS")] StatusOk "Stream is done"
  where
    greeting :: Int -> SSRpy
    greeting i = SSRpy $ "Hello, " <> name <> " - " <> show i

runningSumHandler :: ServerRequest 'ClientStreaming OneInt OneInt -> IO (ServerResponse 'ClientStreaming OneInt)
runningSumHandler (ServerReaderRequest _metadata recv) = loop 0
  where
    loop !i = do
      msg <- recv
      case msg of
        Left err ->
          return
            ( ServerReaderResponse
                Nothing
                []
                StatusUnknown
                (fromString (show err))
            )
        Right (Just (OneInt x)) -> loop (i + x)
        Right Nothing -> do
          return
            ( ServerReaderResponse
                (Just (OneInt i))
                []
                StatusOk
                ""
            )

helloBiHandler :: ServerRequest 'BiDiStreaming BiRqtRpy BiRqtRpy -> IO (ServerResponse 'BiDiStreaming BiRqtRpy)
helloBiHandler (ServerBiDiRequest _metadata recv send) = fix $ \go ->
  recv >>= \case
    Left e -> fail $ "helloBi recv error: " ++ show e
    Right Nothing -> return $ ServerBiDiResponse mempty StatusOk (StatusDetails "helloBi details")
    Right (Just rqt) -> do
      send rqt >>= \case
        Left e -> fail $ "helloBi send error: " ++ show e
        _ -> go

multGoodbyeService :: ServiceOptions -> IO ()
multGoodbyeService = multGoodbyeServer multGoodbyeHandlers

multGoodbyeHandlers :: MultGoodbye ServerRequest ServerResponse
multGoodbyeHandlers =
  MultGoodbye
    { multGoodbyeMult = multHandler
    , multGoodbyeGoodbyeSS = goodbyeSSHandler
    , multGoodbyeRunningProd = runningProdHandler
    }

multHandler :: ServerRequest 'Normal TwoInts OneInt -> IO (ServerResponse 'Normal OneInt)
multHandler (ServerNormalRequest _metadata (TwoInts x y)) = do
  let answer = OneInt (x * y)
  return
    ( ServerNormalResponse
        answer
        [("metadata_key_one", "metadata_value")]
        StatusOk
        "multiplication is easy!"
    )

goodbyeSSHandler :: ServerRequest 'ServerStreaming SSRqt SSRpy -> IO (ServerResponse 'ServerStreaming SSRpy)
goodbyeSSHandler (ServerWriterRequest _metadata (SSRqt name numReplies) ssend) = do
  let range :: [Int]
      range = [1 .. fromIntegral numReplies]

  forM_ range $ \n -> do
    _ <- ssend $ sendoff n
    sleep 0.1

  return $ ServerWriterResponse [("metadata_field", "metadata_value")] StatusOk "Stream is done"
  where
    sendoff i = SSRpy $ "Good Bye, " <> name <> " - " <> show i

runningProdHandler :: ServerRequest 'ClientStreaming OneInt OneInt -> IO (ServerResponse 'ClientStreaming OneInt)
runningProdHandler (ServerReaderRequest _metadata recv) = loop 0
  where
    loop !i = do
      msg <- recv
      case msg of
        Left err ->
          return
            ( ServerReaderResponse
                Nothing
                []
                StatusUnknown
                (fromString (show err))
            )
        Right (Just (OneInt x)) -> loop (i * x)
        Right Nothing ->
          return
            ( ServerReaderResponse
                (Just (OneInt i))
                []
                StatusOk
                ""
            )
