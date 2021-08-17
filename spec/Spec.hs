{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE StandaloneKindSignatures #-}

-- |
--
--

module Spec
  ( check
  )
where

import Control.Monad
import Prelude
import Data.HashMap.Strict (HashMap)
import Data.Kind
import GHC.TypeLits
import qualified Data.HashMap.Strict as HashMap

import Data.Ascript
import Language.Spectacle
import Language.Spectacle.Specification

-- ---------------------------------------------------------------------------------------------------------------------

data Constants = Constants
  { sessionId :: Int
  }

-- ---------------------------------------------------------------------------------------------------------------------

type SpecGRPCMQTT :: [Ascribe Symbol Type]
type SpecGRPCMQTT =
  '[ "controlChan" # [String]
   , "sessionChan" # [String]
   , "serviceChan" # [String]
   -- Maybe iff message needs to be read, if #msg >= 2 incoming then split to seperate process
   , "msgNow"    # Maybe String
   , "methodMap" # HashMap String Int
   , "grpcChans" # HashMap Int [String]
   ]

specInit :: (?constants :: Constants) => Initial SpecGRPCMQTT ()
specInit = do
  #controlChan `define` return []
  #sessionChan `define` return []
  #serviceChan `define` return ["add"]
  #msgNow `define` return Nothing
  #methodMap `define` return (HashMap.fromList [("add", 0)])
  #grpcChans `define` return (HashMap.fromList [(0, [])])

specNext :: (?constants :: Constants) => Action SpecGRPCMQTT Bool
specNext = readChan \/ writeGRPC

readChan :: (?constants :: Constants) => Action SpecGRPCMQTT Bool
readChan = do
  serviceChan <- plain #serviceChan
  case serviceChan of
    []         -> return False
    msg : msgs -> do
      #serviceChan .= return msgs
      #msgNow      .= return (Just msg)
      return True

writeGRPC :: (?constants :: Constants) => Action SpecGRPCMQTT Bool
writeGRPC = do
  msgNow <- plain #msgNow
  case msgNow of
    Nothing  -> return False
    Just msg -> do
      method <- HashMap.lookupDefault 0 "add" <$> plain #methodMap
      #grpcChans .= do
        grpcChans <- plain #grpcChans
        return (grpcChans `HashMap.union` HashMap.fromList [(method, [msg])])
      return True

specProp :: (?constants :: Constants) => Invariant SpecGRPCMQTT Bool
specProp = return True

-- TODO: always initial state is not checked
spec :: (?constants :: Constants) => Specification SpecGRPCMQTT
spec =
  Specification
    { initialAction = specInit
    , nextAction = specNext
    , temporalFormula = specProp
    , terminationFormula = Nothing
    , fairnessConstraint = weakFair
    }

check :: IO ()
check = do
  let ?constants =
        Constants
          { sessionId = 0
          }
  defaultInteraction (modelCheck spec)
