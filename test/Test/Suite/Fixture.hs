{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ImplicitPrelude #-}

module Test.Suite.Fixture
  ( Fixture (Fixture, unFixture),
    testFixture,
  )
where

--------------------------------------------------------------------------------

import Test.Tasty (TestName, TestTree)
import Test.Tasty.HUnit (Assertion, testCase)

--------------------------------------------------------------------------------

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader (MonadReader, ReaderT (ReaderT))

import Data.Kind (Type)

--------------------------------------------------------------------------------

import Test.Suite.Config (TestConfig, withTestConfig)

--------------------------------------------------------------------------------

newtype Fixture (a :: Type) :: Type where
  Fixture :: {unFixture :: TestConfig -> IO a} -> Fixture a
  deriving (Functor, Applicative, Monad)
    via ReaderT TestConfig IO
  deriving
    (MonadIO, MonadReader TestConfig)
    via ReaderT TestConfig IO

testFixture :: TestName -> Fixture () -> TestTree
testFixture desc fixture =
  withTestConfig \config ->
    let prop :: Assertion
        prop = unFixture fixture config
     in testCase desc prop
