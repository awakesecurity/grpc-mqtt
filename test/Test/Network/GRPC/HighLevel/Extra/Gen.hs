{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | Generators for @grpc-haskell@ types.
module Test.Network.GRPC.HighLevel.Extra.Gen
  ( -- * Generators
    metadataMap,
    metadataEntry,
    metadataKey,
    metadataVal,
  )
where

---------------------------------------------------------------------------------

import Hedgehog (MonadGen, Range)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

---------------------------------------------------------------------------------

import Data.Char (ord)
import Data.Word (Word8)

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Map qualified as Map

import Network.GRPC.HighLevel (MetadataMap (MetadataMap))

---------------------------------------------------------------------------------

-- | Generates a 'MetadataMap' using the size parameter to scale the size of the
-- map.
metadataMap :: MonadGen m => m MetadataMap
metadataMap = MetadataMap . Map.fromList <$> sized'list metadataEntry

-- | Generates a single 'MetadataMap' metadata entry using the size parameter to
-- scale the bytestrings in the key-value pair.
metadataEntry :: MonadGen m => m (ByteString, [ByteString])
metadataEntry = do
  key <- metadataKey
  val <- sized'list metadataVal
  pure (key, val)

metadataVal :: MonadGen m => m ByteString
metadataVal =
  Gen.sized \size -> do
    upper <- Gen.int (Range.constant 1 $ fromIntegral size)
    let range :: Range Int
        range = Range.constant 1 upper
     in Gen.bytes range

-- | Generates a valid 'MetadataMap' key.
--
-- prop> metadata key ::= a-z | . | _ | -
metadataKey :: MonadGen m => m ByteString
metadataKey =
  let bytes :: [Word8]
      bytes = map (fromIntegral . ord) ('.' : '_' : '-' : ['a' .. 'z'])
   in ByteString.pack <$> sized'list (Gen.element bytes)

sized'list :: MonadGen m => m a -> m [a]
sized'list gen =
  Gen.sized \size -> do
    upper <- Gen.int (Range.constant 1 (fromIntegral size))
    let range :: Range Int
        range = Range.constant 1 upper
     in Gen.list range gen
