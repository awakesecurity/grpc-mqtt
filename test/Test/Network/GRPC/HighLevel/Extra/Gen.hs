{-# LANGUAGE ImplicitPrelude #-}

-- | Generators for @grpc-haskell@ types.
module Test.Network.GRPC.HighLevel.Extra.Gen
  ( -- * Generators
    metadataMap,
    metadataMapEntry,
  )
where

---------------------------------------------------------------------------------

import Hedgehog (MonadGen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

---------------------------------------------------------------------------------

import Data.ByteString (ByteString)
import Data.String (fromString)

import Network.GRPC.HighLevel (MetadataMap (MetadataMap))

---------------------------------------------------------------------------------
--
-- Generators
--

-- | Generates a 'MetadataMap' using the size parameter to scale the size of the
-- map.
metadataMap :: MonadGen m => m MetadataMap
metadataMap = Gen.sized \size -> do
  high <- Gen.int (Range.constant 1 $ fromIntegral size)
  meta <- Gen.map (Range.constant 0 high) metadataMapEntry
  pure (MetadataMap meta)

-- | Generates a single 'MetadataMap' metadata entry using the size parameter to
-- scale the bytestrings in the key-value pair.
metadataMapEntry :: MonadGen m => m (ByteString, [ByteString])
metadataMapEntry = Gen.sized \size -> do
  high <- Gen.int (Range.constant 1 (fromIntegral size))

  key <- metadataBytes
  val <- Gen.list (Range.constant 1 (1 + high)) metadataBytes

  pure (key, val)

metadataBytes :: MonadGen m => m ByteString
metadataBytes = Gen.sized \size -> do
  high <- Gen.int (Range.constant 1 $ fromIntegral size)
  chrs <- Gen.string (Range.constant 1 (1 + high)) Gen.lower
  pure (fromString chrs)
