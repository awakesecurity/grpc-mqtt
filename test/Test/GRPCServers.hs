{-# LANGUAGE OverloadedLists #-}

module Test.GRPCServers where

import Relude

import Proto.Test

import Network.GRPC.HighLevel
import Network.GRPC.HighLevel.Generated
import UnliftIO.Concurrent (threadDelay)

addHelloService :: ServiceOptions -> IO ()
addHelloService = addHelloServer addHelloHandlers

addHelloHandlers :: AddHello ServerRequest ServerResponse
addHelloHandlers =
  AddHello
    { addHelloAdd = addHandler
    , addHelloHelloSS = helloSSHandler
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
    threadDelay 100000

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
    threadDelay 100000

  return $ ServerWriterResponse [("metadata_field", "metadata_infiniteHelloSS")] StatusOk "Stream is done"
 where
  greeting :: Int -> SSRpy
  greeting i = SSRpy $ "Hello, " <> name <> " - " <> show i

multGoodbyeService :: ServiceOptions -> IO ()
multGoodbyeService = multGoodbyeServer multGoodbyeHandlers

multGoodbyeHandlers :: MultGoodbye ServerRequest ServerResponse
multGoodbyeHandlers =
  MultGoodbye
    { multGoodbyeMult = multHandler
    , multGoodbyeGoodbyeSS = goodbyeSSHandler
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
    threadDelay 100000

  return $ ServerWriterResponse [("metadata_field", "metadata_value")] StatusOk "Stream is done"
 where
  sendoff i = SSRpy $ "Good Bye, " <> name <> " - " <> show i
