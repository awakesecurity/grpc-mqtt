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

import Control.Concurrent.STM.TChan (TChan)
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
  TChan LByteString ->
  WireDecodeOptions ->
  io (m (Maybe ByteString))
makeStreamReader channel options = do
  queue <- atomically newTQueue
  isdone <- newIORef False
  pure (readStreamQueue queue isdone)
  where
    nextStreamChunk :: TQueue ByteString -> IORef Bool -> m ()
    nextStreamChunk queue isdone = do
      runStreamChunkRead channel options >>= \case
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
  TChan LByteString ->
  WireDecodeOptions ->
  m (Maybe (Vector ByteString))
runStreamChunkRead channel options = do
  result <- runExceptT (Packet.makePacketReader channel options)
  case result of
    Left err -> throwError (Message.toRemoteError err)
    Right bs -> wireUnwrapStreamChunk options bs

makeStreamBatchSender ::
  forall io m.
  (MonadIO io, MonadUnliftIO m) =>
  Int ->
  WireEncodeOptions ->
  (ByteString -> m ()) ->
  io (ByteString -> m (), m ())
makeStreamBatchSender limit options publish
  | Serial.encodeBatched options == Batched.Batched = do
    chunksRef <- newIORef ((Vector.empty, 0) :: (Vector ByteString, Int64))
    let send :: ByteString -> m ()
        send chunk = do
          (accChunks, accSize) <- readIORef chunksRef
          let size :: Int64
              size = fromIntegral (ByteString.length chunk)
          if accSize + size < fromIntegral limit
            then atomicWriteIORef chunksRef (Vector.snoc accChunks chunk, accSize + size)
            else do
              (chunks, _) <- readIORef chunksRef
              unless (Vector.null accChunks) $
                makeStreamChunkSender limit options chunks publish
              atomicWriteIORef chunksRef (Vector.singleton chunk, size)

        done :: m ()
        done = do
          (accChunks, _) <- readIORef chunksRef

          unless (Vector.null accChunks) $
            makeStreamChunkSender limit options accChunks publish

          -- Send end of stream indicator
          atomicWriteIORef chunksRef (Vector.empty, 0)
          makeStreamFinalSender limit options publish
     in pure (send, done)
  | otherwise =
    let send :: ByteString -> m ()
        send chunk =
          let chunks :: Vector ByteString
              chunks = Vector.singleton chunk
           in makeStreamChunkSender limit options chunks publish

        done :: m ()
        done = makeStreamFinalSender limit options publish
     in pure (send, done)

makeStreamChunkSender ::
  MonadUnliftIO m =>
  Int ->
  WireEncodeOptions ->
  Vector ByteString ->
  (ByteString -> m ()) ->
  m ()
makeStreamChunkSender limit options chunks publish = do
  let message :: ByteString
      message = wireEncodeStreamChunk options (Just chunks)
   in Packet.makePacketSender limit options publish message

makeStreamFinalSender ::
  MonadUnliftIO m =>
  Int ->
  WireEncodeOptions ->
  (ByteString -> m ()) ->
  m ()
makeStreamFinalSender limit options publish = do
  let message :: ByteString
      message = wireEncodeStreamChunk options Nothing
   in Packet.makePacketSender limit options publish message
