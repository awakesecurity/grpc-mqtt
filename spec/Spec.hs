{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
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
import Data.Type.Rec
import Data.Hashable
import Data.Name
import Prelude
import Data.HashMap.Strict (HashMap)
import Data.Kind
import GHC.TypeLits
import qualified Data.HashMap.Strict as HashMap
import Debug.Trace

import Data.Ascript
import Language.Spectacle.RTS.Registers (RelationTerm)
import Language.Spectacle
import Language.Spectacle.Specification

-- ---------------------------------------------------------------------------------------------------------------------

data Constants = Constants
  { numProcs    :: Int
  , maxChunks   :: Int
  , maxMessages :: Int
  }

type ProcessId = Int

data ProcessState = Running | Done

newtype Message = Message { msgId :: Int, chunks :: Int }
  deriving (Hashable, Show)

newtype Process = Process { channel :: Maybe Message }
 deriving (Hashable, Show)

-- ---------------------------------------------------------------------------------------------------------------------

type SpecGRPCMQTT :: [Ascribe Symbol Type]
type SpecGRPCMQTT =
  '[ "messages"  # [Message]
   , "sessions"  # HashMap Int Int
   , "processes" # HashMap Int Process
   ]

specInit :: (?constants :: Constants) => Initial SpecGRPCMQTT ()
specInit = do
  let Constants {..} = ?constants
  #messages  `define` return []
  #sessions  `define` return HashMap.empty
  #processes `define` return (HashMap.fromList [(n, Process Nothing) | n <- [0 .. numProcs]])


specNext :: (?constants :: Constants) => Action SpecGRPCMQTT Bool
specNext = do
  processes <- plain #processes
  trace (show processes) (pure ())
  newMessage \/ procNext

procNext :: (?constants :: Constants) => Action SpecGRPCMQTT Bool
procNext = do
  let Constants {..} = ?constants
  exists [0 .. numProcs] \procId -> do
    readChan procId -- \/ writeGRPC procId

newMessage :: (?constants :: Constants) => Action SpecGRPCMQTT Bool
newMessage = do
  let Constants {..} = ?constants
  messages <- plain #messages
  if length messages < maxMessages
    then do
      numChunks <- oneOf [0 .. maxChunks]
      #messages .= return (Message numChunks : messages)
      return True
    else return False

readChan :: (?constants :: Constants) => ProcessId -> Action SpecGRPCMQTT Bool
readChan procId = do
  messages <- plain #messages
  case messages of
    msg : msgs -> do
      process <- (HashMap.! procId) <$> plain #processes
      case channel process of
        Nothing  -> do
          #messages .= return msgs
          #processes .= #processes `except` (procId, Process (Just msg))
          return True
        Just msg -> return False
    [] -> return False

writeGRPC :: (?constants :: Constants) => ProcessId -> Action SpecGRPCMQTT Bool
writeGRPC procId = do
  process <- (HashMap.! procId) <$> plain #processes
  case channel process of
    Nothing  -> return False
    Just msg
      | chunks == 0 -> _
      | otherwise -> _

removeMessage :: ProcessId -> Action SpecGRPCMQTT Bool
removeMessage prodId = do
  process <- (HashMap.! procId) <$> plain #processes
  case channel of
    Nothing -> return False
    Just msg
      | chunks msg == 0 -> #processes .= #processes `except` (procId, Process Nothing)
      | otherwise -> return False

except :: (Eq a, Hashable a, s # HashMap a b .| ctx) => Name s -> (a, b) -> RelationTerm ctx (HashMap a b)
except name (k, v) = HashMap.insert k v <$> plain name

specProp :: (?constants :: Constants) => Invariant SpecGRPCMQTT Bool
specProp = do

  messages  <- plain #messsage
  messages' <- prime #messsage

  -- Props
  --
  -- Need to model the message order.
  --
  -- Chunks 3 --> Chunks 2 --> Chunks 1 --> Chunks 0 --> Done
  --
  -- forall ix :: Int -> (p : Process ix)
  -- if numChunks p /= 0
  --   then p' == Process Nothing
  --
  return True

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
check =
  let ?constants = Constants { numProcs = 2, maxMessages = 2, maxChunks = 2 }
  in defaultInteraction (modelCheck spec)


-- type SpecGRPCMQTT :: [Ascribe Symbol Type]
-- type SpecGRPCMQTT =
--   '[ "controlChan" # [String]
--    , "sessionChan" # [String]
--    , "serviceChan" # [String]
--    -- Maybe iff message needs to be read, if #msg >= 2 incoming then split to seperate process
--    , "msgNow"    # Maybe String
--    , "methodMap" # HashMap String Int
--    , "grpcChans" # HashMap Int [String]
--    ]

-- specInit :: (?constants :: Constants) => Initial SpecGRPCMQTT ()
-- specInit = do
--   #controlChan `define` return []
--   #sessionChan `define` return []
--   #serviceChan `define` return ["add"]
--   #msgNow      `define` return Nothing
--   #methodMap   `define` return (HashMap.fromList [("add", 0)])
--   #grpcChans   `define` return (HashMap.fromList [(0, [])])

-- specNext :: (?constants :: Constants) => Action SpecGRPCMQTT Bool
-- specNext = readChan \/ writeGRPC

-- readChan :: (?constants :: Constants) => Action SpecGRPCMQTT Bool
-- readChan = do
--   serviceChan <- plain #serviceChan
--   case serviceChan of
--     []         -> return False
--     msg : msgs -> do
--       #serviceChan .= return msgs
--       #msgNow      .= return (Just msg)
--       return True

-- writeGRPC :: (?constants :: Constants) => Action SpecGRPCMQTT Bool
-- writeGRPC = do
--   msgNow <- plain #msgNow
--   case msgNow of
--     Nothing  -> return False
--     Just msg -> do
--       method <- HashMap.lookupDefault 0 "add" <$> plain #methodMap
--       #grpcChans .= do
--         grpcChans <- plain #grpcChans
--         return (grpcChans `HashMap.union` HashMap.fromList [(method, [msg])])
--       return True

-- except ::
--   (Eq a, Hashable a, s # HashMap a b .| ctx) =>
--   Name s -> (a, b) -> RelationTerm ctx (HashMap a b)
-- except name (k, v) = HashMap.insert k v <$> plain name

-- specProp :: (?constants :: Constants) => Invariant SpecGRPCMQTT Bool
-- specProp = return True

-- -- TODO: always initial state is not checked
-- spec :: (?constants :: Constants) => Specification SpecGRPCMQTT
-- spec =
--   Specification
--     { initialAction = specInit
--     , nextAction = specNext
--     , temporalFormula = specProp
--     , terminationFormula = Nothing
--     , fairnessConstraint = weakFair
--     }

-- check :: IO ()
-- check = do
--   let ?constants =
--         Constants
--           { sessionId = 0
--           }
--   defaultInteraction (modelCheck spec)
