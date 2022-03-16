-- | TODO: docs
module Network.GRPC.MQTT.Wrap.Core
  ( -- * Wrap Monad
    Wrap,
    unwrap,

    -- ** Pattern Synonyms
    pattern WrapEither,
    pattern WrapRight,
    pattern WrapError,

    -- * Wrap Transformer
    WrapT (WrapT, unwrapT),
    hoistWrapT,
  )
where

import Control.Monad.Fix (MonadFix)
import Control.Monad.Except (MonadError)
import Data.Functor.Classes (Show1, showsPrec1)
import GHC.Exts (Proxy#, proxy#)
import Text.Show (showsPrec)

-- proto3-suite & proto3-wire -----
import Proto3.Suite
  ( HasDefault (def),
    Message (decodeMessage, dotProto, encodeMessage),
    Named (nameOf),
  )
import Proto3.Wire.Decode qualified as Wire.Decode
import Proto3.Wire.Encode qualified as Wire.Encode

import Proto.Mqtt (RemoteError)

--------------------------------------------------------------------------------

-- TODO: docs
type Wrap :: Type -> Type
type Wrap = WrapT Identity

-- | Construct a 'Wrap' from an @'Either' 'RemoteError' a@.
--
-- prop> 'WrapEither' == 'WrapT' . 'ExceptT' . 'Identity'
--
-- @since 1.0.0
pattern WrapEither :: Either RemoteError a -> Wrap a
pattern WrapEither{unwrap} = WrapT (Identity unwrap)

-- | Construct a 'Wrapped' from a type @a@.
--
-- prop> 'WrapRight' == 'WrapEither' . 'Right'
--
-- @since 1.0.0
pattern WrapRight :: a -> Wrap a
pattern WrapRight err = WrapEither (Right err)

-- | Construct a 'Wrapped' from a RemoteError.
--
-- prop> 'WrapError' == 'WrapEither' . 'Left'
--
-- @since 1.0.0
pattern WrapError :: RemoteError -> Wrap a
pattern WrapError err = WrapEither (Left err)

{-# COMPLETE WrapError, WrapRight #-}

-- | @since 1.0.0
instance Named a => Named (Wrap a) where
  nameOf _ =
    let nm :: String
        nm = nameOf (proxy# :: Proxy# a)
     in fromString ("Wrap" ++ nm)
  {-# INLINE CONLIKE nameOf #-}

-- | @since 1.0.0
instance (HasDefault a, Message a) => Message (Wrap a) where
  encodeMessage _ = \case
    WrapError e -> Wire.Encode.embedded 2 (encodeMessage 2 e)
    WrapRight x -> Wire.Encode.embedded 1 (encodeMessage 1 x)

  decodeMessage _ =
    Wire.Decode.oneof
      (WrapError def)
      [ (1, maybe (WrapError def) WrapRight <$> Wire.Decode.embedded (decodeMessage 1))
      , (2, maybe (WrapRight def) WrapRight <$> Wire.Decode.embedded (decodeMessage 2))
      ]

  dotProto _ = [] -- FIXME:

--------------------------------------------------------------------------------

-- | TODO: docs
newtype WrapT m a = WrapT
  {unwrapT :: m (Either RemoteError a)}
  deriving stock (Generic)
  deriving
    (Applicative, Monad, MonadFix, MonadError RemoteError)
    via ExceptT RemoteError m
  deriving
    (Eq, Ord)
    via ExceptT RemoteError m a

-- | @since 1.0.0
instance (Show1 m, Show a) => Show (WrapT m a) where
  showsPrec i = showsPrec1 i . unwrapT
  {-# INLINE showsPrec #-}

-- | @since 1.0.0
instance Functor m => Functor (WrapT m) where
  fmap f = WrapT . fmap (fmap f) . unwrapT
  {-# INLINE fmap #-}

-- | @since 1.0.0
instance MonadIO m => MonadIO (WrapT m) where
  liftIO = WrapT . liftIO . fmap Right
  {-# INLINE liftIO #-}

-- | @since 1.0.0
instance MonadTrans WrapT where
  lift = WrapT . fmap Right
  {-# INLINE lift #-}

-- |
--
-- @since 1.0.0
hoistWrapT :: (forall x. f x -> g x) -> WrapT f a -> WrapT g a
hoistWrapT eta (WrapT x) = WrapT (eta x)
