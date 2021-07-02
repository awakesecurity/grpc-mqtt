module Test.Helpers where

import Relude

import Data.Default (Default (def))
import qualified Data.Text.Lazy as TL
import Data.X509.CertificateStore (
  CertificateStore,
  readCertificateStore,
 )
import Network.Connection (TLSSettings (TLSSettings))
import Network.GRPC.HighLevel.Client (MetadataMap, StreamRecv)
import Network.GRPC.MQTT (
  MQTTConfig (_hostname, _port, _protocol, _tlsSettings),
  ProtocolLevel (Protocol311),
  mqttConfig,
 )
import Network.TLS (
  ClientHooks (onCertificateRequest),
  ClientParams (clientHooks, clientShared, clientSupported),
  Credential,
  Credentials (Credentials),
  HostName,
  Shared (sharedCAStore, sharedCredentials),
  Supported (supportedCiphers),
  credentialLoadX509,
  defaultParamsClient,
 )
import Network.TLS.Extra.Cipher (ciphersuite_default)
import Test.Tasty (DependencyType (AllFinish), TestName, TestTree, after)
import Test.Tasty.HUnit (
  Assertion,
  assertBool,
  assertFailure,
  testCase,
 )
import Test.Tasty.Runners (timed)

awsMqttConfig :: HostName -> Credential -> CertificateStore -> MQTTConfig
awsMqttConfig hostName cred certStore =
  mqttConfig
    { _protocol = Protocol311
    , _hostname = hostName
    , _port = 8883
    , _tlsSettings =
        TLSSettings
          (defaultParamsClient hostName "")
            { clientShared =
                def
                  { sharedCredentials = Credentials [cred]
                  , sharedCAStore = certStore
                  }
            , clientHooks = def{onCertificateRequest = \_ -> return (Just cred)}
            , clientSupported = def{supportedCiphers = ciphersuite_default}
            }
    }

getCreds :: IO (Credential, CertificateStore)
getCreds = do
  cred <-
    credentialLoadX509 "test/certs/759594fd70-certificate.pem.crt" "test/certs/759594fd70-private.pem.key" >>= \case
      Right c -> pure c
      Left err -> assertFailure err
  certStore <-
    readCertificateStore "test/certs/" >>= \case
      Just cs -> pure cs
      Nothing -> assertFailure "Failed to read cert store"
  return (cred, certStore)

getTestConfig :: HostName -> IO MQTTConfig
getTestConfig host = do
  (cred, certStore) <- getCreds
  return $ awsMqttConfig host cred certStore

assertContains :: LText -> LText -> Assertion
assertContains substr str = assertBool (show $ "Stream response: " <> str <> ", did not contain " <> substr) (substr `TL.isInfixOf` str)

timeit :: Double -> IO a -> IO a
timeit limit action = do
  (seconds, res) <- timed action
  let timeMsg = "Time: " <> show seconds <> "s"
  assertBool timeMsg $ seconds < limit
  return res

streamTester :: (response -> Assertion) -> MetadataMap -> StreamRecv response -> IO ()
streamTester assertProp _mm sr = loop
 where
  loop =
    sr >>= \case
      Left err -> assertFailure (show err)
      Right Nothing -> pure ()
      Right (Just rsp) -> assertProp rsp >> loop

notParallel :: [(TestName, Assertion)] -> [TestTree]
notParallel = foldr f []
 where
  f :: (TestName, Assertion) -> [TestTree] -> [TestTree]
  f (name, t) [] = [testCase name t]
  f (name, t) (lt : rest) = testCase name t : after AllFinish name lt : rest
