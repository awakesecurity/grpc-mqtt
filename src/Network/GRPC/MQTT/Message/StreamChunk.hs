module Network.GRPC.MQTT.Message.StreamChunk
  ( -- * Stream Chunks
    WrappedStreamChunk (Chunk, Empty, Error),

    -- ** Wire Encoding
    wireWrapStreamChunk,

    -- ** Wire Decoding
    wireUnwrapStreamChunk,
  )
where

--------------------------------------------------------------------------------

import Control.Monad.Except (MonadError, throwError)

import Data.Vector (Vector)

import Proto3.Suite qualified as Proto3

-- import Proto3.Suite.Class (Message)

import Relude

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Wrapping qualified as Wrapping

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
wireWrapStreamChunk :: Maybe (Vector ByteString) -> WrappedStreamChunk
wireWrapStreamChunk (Just cxs) = Chunk cxs
wireWrapStreamChunk Nothing = Empty

-- Stream Chunks - Wire Decoding -----------------------------------------------

-- | TODO
--
-- @since 0.1.0.0
wireUnwrapStreamChunk ::
  MonadError RemoteError m =>
  ByteString ->
  m (Maybe (Vector ByteString))
wireUnwrapStreamChunk bytes =
  case Proto3.fromByteString bytes of
    Left err -> throwError (Wrapping.parseErrorToRCE err)
    Right (Error err) -> throwError err
    Right Empty -> pure Nothing
    Right (Chunk cxs) -> pure (Just cxs)
