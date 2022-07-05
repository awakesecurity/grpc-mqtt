module Network.GRPC.MQTT.Message.StreamChunk
  ( -- * Stream Chunks
    WrappedStreamChunk (Chunk, Empty, Error),
  )
where

--------------------------------------------------------------------------------

import Data.Vector (Vector)

import Relude

--------------------------------------------------------------------------------

import Proto.Mqtt (RemoteError, WrappedStreamChunk)
import Proto.Mqtt qualified as Proto

--------------------------------------------------------------------------------

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