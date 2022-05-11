{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | TODO
module Test.Suite.Fixture
  ( -- * TODO
    Fixture (Fixture, unFixture),
    testFixture,
  )
where

--------------------------------------------------------------------------------

import Test.Tasty (TestName, TestTree)
import Test.Tasty.HUnit (Assertion, testCase)

--------------------------------------------------------------------------------

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader
  ( MonadReader,
    ReaderT (ReaderT),
    ask,
    runReader,
    runReaderT,
  )
import Control.Monad.Trans (MonadTrans, lift)

import Data.Kind (Type)

import GHC.Stack (HasCallStack)

--------------------------------------------------------------------------------

import Test.Suite.Config

--------------------------------------------------------------------------------


--------------------------------------------------------------------------------

-- | TODO
newtype Fixture (a :: Type) :: Type where
  Fixture :: {unFixture :: ReaderT TestConfig IO a} -> Fixture a
  deriving (Functor, Applicative, Monad)
  deriving
    (MonadIO, MonadReader TestConfig)
    via ReaderT TestConfig IO

-- | TODO
runFixture :: TestConfig -> Fixture a -> IO a
runFixture config (Fixture m) = runReaderT m config

-- | TODO
testFixture :: TestName -> Fixture () -> TestTree
testFixture desc (Fixture m) =
  withTestConfig \config ->
    let prop :: Assertion
        prop = runReaderT m config
     in testCase desc prop

-- | TODO
-- forAll :: (Monad m, Show a, HasCallStack) => Gen a -> FixtureT m a
-- forAll gen = FixtureT (lift (Hedgehog.forAll gen))
