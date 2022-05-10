{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | TODO
module Test.Suite.Fixture
  ( -- * TODO
    Fixture (Fixture, unFixture),
    testFixture,
    fixture,

    -- * TODO
    FixtureT (FixtureT, unFixtureT),
    runFixtureT,
    forAll,
  )
where

--------------------------------------------------------------------------------

import Hedgehog (Gen, MonadTest, Property, PropertyT, property, withTests)
import Hedgehog qualified as Hedgehog

import Test.Tasty (TestName, TestTree)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.IO.Unlift
  ( MonadUnliftIO,
    withRunInIO,
    wrappedWithRunInIO,
  )
import Control.Monad.Reader
  ( MonadReader,
    Reader,
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

-- | TODO
newtype Fixture = Fixture
  {unFixture :: Reader TestConfig Property}

-- | TODO
testFixture :: TestName -> Fixture -> TestTree
testFixture desc (Fixture m) =
  withTestConfig \config ->
    let prop :: Property
        prop = runReader m config
     in testProperty desc prop

-- | TODO
fixture :: FixtureT IO () -> Fixture
fixture (FixtureT k) = Fixture do
  config <- ask
  let propT :: PropertyT IO ()
      propT = runReaderT k config
   in pure (withTests 1 (property propT))

--------------------------------------------------------------------------------

-- | TODO
newtype FixtureT (m :: Type -> Type) (a :: Type) :: Type where
  FixtureT :: {unFixtureT :: ReaderT TestConfig (PropertyT m) a} -> FixtureT m a
  deriving (Functor, Applicative, Monad)
  deriving
    (MonadIO, MonadReader TestConfig, MonadTest)
    via ReaderT TestConfig (PropertyT m)

-- | TODO
runFixtureT :: TestConfig -> FixtureT m a -> PropertyT m a
runFixtureT config (FixtureT m) = runReaderT m config

instance MonadTrans FixtureT where
  lift = FixtureT . lift . lift

-- | TODO
forAll :: (Monad m, Show a, HasCallStack) => Gen a -> FixtureT m a
forAll gen = FixtureT (lift (Hedgehog.forAll gen))
