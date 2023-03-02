module Test.Network.GRPC.MQTT.Message.Packet
  ( -- * Test Tree
    tests,
  )
where

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------

import Hedgehog (Property, forAll, property, tripping, (===))
import Hedgehog qualified

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Test.Network.GRPC.MQTT.Message.Gen qualified as Message.Gen

--------------------------------------------------------------------------------

import Control.Concurrent.Async (concurrently)

import Control.Concurrent.STM.TQueue
  ( TQueue,
    flushTQueue,
    newTQueueIO,
    writeTQueue,
  )

import Relude hiding (reader)

--------------------------------------------------------------------------------

import Network.GRPC.MQTT.Message.Packet qualified as Packet

import Data.ByteString qualified as ByteString
import Proto3.Wire.Decode (ParseError)

import Data.Fixed (Fixed (MkFixed), Pico)
import Data.Time.Clock (diffUTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

--------------------------------------------------------------------------------

data TestLabels
  = PacketClientCompress
  | PacketRemoteCompress
  deriving (Show)

tests :: TestTree
tests =
  testGroup
    "Network.GRPC.MQTT.Message.Packet"
    [ testProperty "Packet.Wire" propPacketWire
    , testProperty "Packet.Handle" propPacketHandle
    , testProperty "Packet.HandleOrder" propPacketHandleOrder
    , testProperty "Packet.MaxSize" propPacketMaxSize
    , testProperty "Packet.RateLimit" propPacketRateLimit
    ]

propPacketWire :: Property
propPacketWire = property do
  packet <- forAll Message.Gen.packet
  tripping @_ @(Either ParseError)
    packet
    Packet.wireWrapPacket'
    Packet.wireUnwrapPacket

propPacketHandle :: Property
propPacketHandle = property do
  message <- forAll Message.Gen.packetBytes
  maxsize <- forAll (Message.Gen.packetSplitLength message)
  queue <- Hedgehog.evalIO newTQueueIO

  let reader :: ExceptT ParseError IO ByteString
      reader = Packet.makePacketReader queue

  let sender :: ByteString -> IO ()
      sender = Packet.makePacketSender maxsize Nothing (mockPublish queue)

  ((), result) <- Hedgehog.evalIO do
    concurrently (sender message) (runExceptT reader)

  Right message === result

propPacketHandleOrder :: Property
propPacketHandleOrder = property do
  message <- forAll Message.Gen.packetBytes
  maxsize <- forAll (Message.Gen.packetSplitLength message)
  queue <- Hedgehog.evalIO newTQueueIO

  let maxPayloadSize :: Word32
      maxPayloadSize = max 1 (maxsize - Packet.minPacketSize)

  let nPackets :: Word32
      nPackets = max 1 (quotInf (fromIntegral $ ByteString.length message) maxPayloadSize)

  let packetsOrig :: [Packet.Packet ByteString]
      packetsOrig =
        if ByteString.length message == 0
          then [Packet.Packet message 0 1]
          else getPackets 0 message
        where
          getPackets i bs =
            case ByteString.splitAt (fromIntegral maxPayloadSize) bs of
              (chunk, rest)
                | ByteString.null chunk -> []
                | otherwise -> Packet.Packet chunk i nPackets : getPackets (i + 1) rest

  packets <- forAll (Gen.shuffle (packetsOrig ++ packetsOrig))

  let reader :: ExceptT ParseError IO ByteString
      reader = Packet.makePacketReader queue

  let sender :: IO ()
      sender =
        forM_ packets $ \packet -> do
          mockPublish queue (Packet.wireWrapPacket' packet)

  ((), result) <- Hedgehog.evalIO do
    concurrently sender (runExceptT reader)

  Right message === result

quotInf :: Integral a => a -> a -> a
quotInf x y = quot (x + (y - 1)) y

mockPublish :: TQueue ByteString -> ByteString -> IO ()
mockPublish queue message = atomically (writeTQueue queue message)

propPacketMaxSize :: Property
propPacketMaxSize = property do
  message <- forAll Message.Gen.packetBytes
  maxsize <- forAll (Message.Gen.packetSplitLength message)
  queue <- Hedgehog.evalIO newTQueueIO

  let sender :: ByteString -> IO ()
      sender = Packet.makePacketSender maxsize Nothing (atomically . writeTQueue queue)

  packets <- Hedgehog.evalIO do
    sender message
    atomically (flushTQueue queue)

  for_ packets \packet ->
    let size :: Word32
        size = fromIntegral (ByteString.length packet)
     in Hedgehog.assert (size <= maxsize)

propPacketRateLimit :: Property
propPacketRateLimit = Hedgehog.withTests 20 $ property do
  message <- forAll Message.Gen.packetBytes
  let messageLength = ByteString.length message
  maxsize <- forAll (Message.Gen.packetSplitLength message)
  let rateLimitRange :: Range.Range Natural
      rateLimitRange = Range.linear (fromIntegral maxsize) (fromIntegral messageLength)
  rateLimit <- forAll (Gen.integral_ rateLimitRange)

  queue <- Hedgehog.evalIO newTQueueIO

  let reader :: ExceptT ParseError IO ByteString
      reader = Packet.makePacketReader queue

  let sender :: ByteString -> IO ()
      sender = Packet.makePacketSender maxsize (Just rateLimit) (atomically . writeTQueue queue)

  (result, sendTime) <- Hedgehog.evalIO $ do
    t1 <- getCurrentTime
    sender message
    t2 <- getCurrentTime
    result <- runExceptT reader
    pure (result, nominalDiffTimeToSeconds $ diffUTCTime t2 t1)

  Right message === result

  let minTime :: Pico
      minTime = MkFixed $ 1_000_000_000_000 * (fromIntegral messageLength `div` fromIntegral rateLimit)
  Hedgehog.diff sendTime (>=) minTime
