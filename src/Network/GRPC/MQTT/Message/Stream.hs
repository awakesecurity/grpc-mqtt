module Network.GRPC.MQTT.Message.Stream
  ( -- * Stream Chunks
    WrappedStreamChunk (Chunk, Empty, Error),

    -- ** Wire Encoding
    wireEncodeStreamChunk,
    wireWrapStreamChunk,

    -- ** Wire Decoding
    wireUnwrapStreamChunk,

    -- * Stream Chunk Readers
    makeStreamReader,
    runStreamChunkRead,

    -- * Stream Chunk Senders
    makeStreamBatchSender,
    makeStreamChunkSender,
    makeStreamFinalSender,
  )
where

--------------------------------------------------------------------------------

import Control.Concurrent.STM.TQueue (TQueue, isEmptyTQueue, readTQueue)

import Control.Monad.Except (MonadError, throwError)

import Data.ByteString qualified as ByteString
import Data.Vector (Vector)
import Data.Vector qualified as Vector

import Relude hiding (atomically)

import UnliftIO (MonadUnliftIO)
import UnliftIO.STM
  ( atomically,
    newTQueue,
    writeTQueue,
  )

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message qualified as Message
import Network.GRPC.MQTT.Message.Packet qualified as Packet

import Network.GRPC.MQTT.Option.Batched qualified as Batched

import Network.GRPC.MQTT.Serial (WireDecodeOptions, WireEncodeOptions)
import Network.GRPC.MQTT.Serial qualified as Serial

import Proto.Mqtt (RemoteError, WrappedStreamChunk)
import Proto.Mqtt qualified as Proto
import Network.GRPC.MQTT.Wrapping (parseErrorToRCE)

-- Stream Chunks ---------------------------------------------------------------

pattern Chunk :: Vector ByteString -> WrappedStreamChunk
pattern Chunk cxs =
  Proto.WrappedStreamChunk
    ( Just
        ( Proto.WrappedStreamChunkOrErrorElems
            (Proto.WrappedStreamChunk_Elems cxs)
          )
      )

pattern Error :: RemoteError -> WrappedStreamChunk
pattern Error err =
  Proto.WrappedStreamChunk (Just (Proto.WrappedStreamChunkOrErrorError err))

pattern Empty :: WrappedStreamChunk
pattern Empty = Proto.WrappedStreamChunk Nothing

{-# COMPLETE Chunk, Empty, Error #-}

-- Stream Chunks - Wire Encoding -----------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
wireEncodeStreamChunk ::
  WireEncodeOptions ->
  Maybe (Vector ByteString) ->
  ByteString
wireEncodeStreamChunk options chunks =
  let wrapped :: WrappedStreamChunk
      wrapped = wireWrapStreamChunk chunks
   in Message.toWireEncoded options wrapped

-- | TODO
--
-- @since 0.1.0.0
wireWrapStreamChunk :: Maybe (Vector ByteString) -> WrappedStreamChunk
wireWrapStreamChunk (Just cxs) = Chunk cxs
wireWrapStreamChunk Nothing = Empty

-- Stream Chunks - Wire Decoding -----------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
wireUnwrapStreamChunk ::
  MonadError RemoteError m =>
  WireDecodeOptions ->
  ByteString ->
  m (Maybe (Vector ByteString))
wireUnwrapStreamChunk options bytes =
  case Message.fromWireEncoded @_ @WrappedStreamChunk options bytes of
    Left err -> throwError (Message.toRemoteError err)
    Right (Error err) -> throwError err
    Right Empty -> pure Nothing
    Right (Chunk cxs) -> pure (Just cxs)

-- Stream Chunk Handlers -------------------------------------------------------

makeStreamReader ::
  forall io m.
  (MonadIO io, MonadError RemoteError m, MonadIO m) =>
  TQueue ByteString ->
  WireDecodeOptions ->
  io (m (Maybe ByteString))
makeStreamReader source options = do
  -- TODO: document 'makeStreamReader' how buffering the stream chunks here, 
  -- noting interactions with other functions such as 'makeClientStreamReader'.
  queue <- atomically newTQueue
  isdone <- newIORef False
  pure (readStreamQueue queue isdone)
  where
    nextStreamChunk :: TQueue ByteString -> IORef Bool -> m ()
    nextStreamChunk queue isdone = do
      runStreamChunkRead source options >>= \case
        Nothing -> writeIORef isdone True
        Just cs -> liftIO (atomically (mapM_ (writeTQueue queue) cs))

    readStreamQueue :: 
      TQueue ByteString ->
      IORef Bool -> 
      m (Maybe ByteString)
    readStreamQueue queue isdone = do
      isQueueEmpty <- atomically (isEmptyTQueue queue)
      if isQueueEmpty 
        then do 
          isStreamDone <- readIORef isdone
          if isStreamDone
            then pure Nothing
            else do 
              nextStreamChunk queue isdone
              readStreamQueue queue isdone
        else do 
          chunk <- atomically (readTQueue queue)
          pure (Just chunk)
      
runStreamChunkRead ::
  (MonadIO m, MonadError RemoteError m) =>
  TQueue ByteString ->
  WireDecodeOptions ->
  m (Maybe (Vector ByteString))
runStreamChunkRead channel options = do
  result <- runExceptT (Packet.makePacketReader channel)
  case result of
    Left err -> throwError (parseErrorToRCE err)
    Right bs -> wireUnwrapStreamChunk options bs

makeStreamBatchSender ::
  forall io m.
  (MonadIO io, MonadUnliftIO m) =>
  Word32 ->
  Maybe Word32 ->
  WireEncodeOptions ->
  (ByteString -> m ()) ->
  io (ByteString -> m (), m ())
makeStreamBatchSender packetSizeLimit rateLimit options publish
  | Serial.encodeBatched options == Batched.Batched = do
    chunksRef <- newIORef ((Vector.empty, 0) :: (Vector ByteString, Int64))
    let send :: ByteString -> m ()
        send chunk = do
          (accChunks, accSize) <- readIORef chunksRef
          let size :: Int64
              size = fromIntegral (ByteString.length chunk)
          if accSize + size < fromIntegral packetSizeLimit
            then atomicWriteIORef chunksRef (Vector.snoc accChunks chunk, accSize + size)
            else do
              (chunks, _) <- readIORef chunksRef
              unless (Vector.null accChunks) $
                makeStreamChunkSender packetSizeLimit rateLimit options chunks publish
              atomicWriteIORef chunksRef (Vector.singleton chunk, size)

        done :: m ()
        done = do
          (accChunks, _) <- readIORef chunksRef

          unless (Vector.null accChunks) $
            makeStreamChunkSender packetSizeLimit rateLimit options accChunks publish

          -- Send end of stream indicator
          atomicWriteIORef chunksRef (Vector.empty, 0)
          makeStreamFinalSender packetSizeLimit rateLimit options publish
     in pure (send, done)
  | otherwise =
    let send :: ByteString -> m ()
        send chunk =
          let chunks :: Vector ByteString
              chunks = Vector.singleton chunk
           in makeStreamChunkSender packetSizeLimit rateLimit options chunks publish

        done :: m ()
        done = makeStreamFinalSender packetSizeLimit rateLimit options publish
     in pure (send, done)

makeStreamChunkSender ::
  MonadUnliftIO m =>
  Word32 ->
  Maybe Word32 ->
  WireEncodeOptions ->
  Vector ByteString ->
  (ByteString -> m ()) ->
  m ()
makeStreamChunkSender packetSizeLimit rateLimit options chunks publish = do
  let message :: ByteString
      message = wireEncodeStreamChunk options (Just chunks)
   in Packet.makePacketSender packetSizeLimit rateLimit publish message

makeStreamFinalSender ::
  MonadUnliftIO m =>
  Word32 ->
  Maybe Word32 ->
  WireEncodeOptions ->
  (ByteString -> m ()) ->
  m ()
makeStreamFinalSender packetSizeLimit rateLimit options publish = do
  let message :: ByteString
      message = wireEncodeStreamChunk options Nothing
   in Packet.makePacketSender packetSizeLimit rateLimit publish message
