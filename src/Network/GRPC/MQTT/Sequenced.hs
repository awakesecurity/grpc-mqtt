{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Network.GRPC.MQTT.Sequenced where

import Relude

import qualified Data.SortedList as SL
import Proto.Mqtt (SequencedResponse (..))
import Proto3.Suite (toLazyByteString)

-- | A class representing types that have some form of sequence id
class Sequenced a where
  type Payload a
  seqNum :: a -> Int
  seqPayload :: a -> Payload a

-- | A newtype wrapper to use 'seqNum` for its 'Ord' and 'Eq' instances
newtype SequencedWrap a = SequencedWrap a
  deriving stock (Show)
  deriving newtype (Sequenced)

instance (Sequenced sa) => Eq (SequencedWrap sa) where
  (==) = (==) `on` seqNum

instance (Sequenced sa) => Ord (SequencedWrap sa) where
  (<=) = (<=) `on` seqNum

-- 'Either' can be sequenced where 'Left' represents an error and will
-- always be given first in the sequence
instance (Sequenced a) => Sequenced (Either e a) where
  type Payload (Either e a) = Either e (Payload a)
  seqNum (Left _) = minBound
  seqNum (Right a) = seqNum a
  seqPayload = fmap seqPayload

instance Sequenced SequencedResponse where
  type Payload SequencedResponse = ByteString
  seqNum = fromIntegral . sequencedResponseSequenceNum
  seqPayload = sequencedResponsePayload

{- | Given an 'STM' action that gets a 'Sequenced' object, creates a new wrapped action that will
 read the objects in order even if they are received out of order
 NB: Objects with negative sequence numbers are always returned immediately
-}
mkSequencedRead :: forall m a. (MonadIO m, Sequenced a) => STM a -> m (m (Payload a))
mkSequencedRead read = do
  seqVar <- newTVarIO 0
  bufferVar <- newTVarIO $ SL.toSortedList @(SequencedWrap a) []

  let orderedRead :: STM (Payload a)
      orderedRead = do
        curSeq <- readTVar seqVar
        buffer <- readTVar bufferVar

        sa <- case SL.uncons buffer of
          Just (sa, rest)
            | curSeq == seqNum sa -> writeTVar bufferVar rest $> sa
          _ -> coerce read

        if seqNum sa < 0
          then return $ seqPayload sa
          else case seqNum sa `compare` curSeq of
            -- If sequence number is less than current, it must be a duplicate, so we discard it and read again
            LT -> orderedRead
            EQ -> modifyTVar' seqVar (+ 1) $> seqPayload sa
            GT -> modifyTVar' bufferVar (SL.insert sa) >> orderedRead

  return $ atomically orderedRead

-- | Wraps a publish function to tag each response as a 'SequencedResponse' with an incrementing sequence number
mkSequencedPublish :: (MonadIO m) => (LByteString -> m a) -> m (LByteString -> m a)
mkSequencedPublish pub = do
  seqVar <- newTVarIO 0
  let sequencedPublish msg = do
        sr <- atomically $ do
          curSeq <- readTVar seqVar
          modifyTVar' seqVar (+ 1)
          return $ SequencedResponse (toStrict msg) curSeq
        pub $ toLazyByteString sr
  return sequencedPublish
