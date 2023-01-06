{-# LANGUAGE TemplateHaskellQuotes #-}
-- See [NOTE: Enforcing Message Splice Order]
{-# OPTIONS_GHC -Wno-unused-imports #-}

-- |
-- Module      :  Network.GRPC.MQTT.Message.TH
-- Copyright   :  (c) Arista Networks, 2022-2023
-- License     :  Apache License 2.0, see COPYING
--
-- Stability   :  stable
-- Portability :  non-portable (GHC extensions)
--
-- Definitions of template haskell splices used by 'Network.GRPC.MQTT.Message'
-- message types.
--
-- @since 1.0.0
module Network.GRPC.MQTT.Message.TH
  ( -- * Record Introspection
    reifyFieldNumber,
    reifyRecordField,
  )
where

---------------------------------------------------------------------------------

import Data.Word (Word64)

import Data.List qualified as List

import Proto3.Wire qualified as Proto3

import Language.Haskell.TH (Bang, Con, Dec, Exp, Info, Name, Q, Type)
import Language.Haskell.TH qualified as TH

import Relude hiding (Type)

import Text.Show (shows)

---------------------------------------------------------------------------------

import Proto3.Wire.Types.Extra (RecordField (RecordField))
import Proto3.Wire.Types.Extra.TH qualified as TH

-- [NOTE: Enforcing Message Splice Order]
--
-- If 'TH.reify' is given the name of a type, then that type must be in template
-- haskell's "type environment" in order for 'TH.reify' to be able to resolve
-- the name into an 'Info' value. This requirement imposes a restriction on where
-- splice naming a types can be used.
--
-- To get around this restriction, message type declarations are split into core
-- modules and imported here. Structuring the modules this forces GHC to compile
-- core modules before this module and exposes the message type declarations
-- avaliable 'TH.reify'.
import Network.GRPC.MQTT.Message.Request.Core (Request)

---------------------------------------------------------------------------------

reifyFieldNumber :: Name -> Name -> Q Exp
reifyFieldNumber recNm selNm = do
  selNms <- selectorsOf recNm
  case List.elemIndex selNm selNms of
    Nothing ->
      let issue :: String
          issue = shows recNm " has no selector with the name " ++ show selNm
       in throwQ 'reifyRecordField issue
    Just ix -> do
      let fieldnum :: Word64
          fieldnum = 1 + fromIntegral @Int @Word64 ix
       in TH.liftFieldNumber (Proto3.FieldNumber fieldnum)

reifyRecordField :: Name -> Name -> Q Exp
reifyRecordField recNm selNm = do
  selNms <- selectorsOf recNm
  case List.elemIndex selNm selNms of
    Nothing ->
      let issue :: String
          issue = shows recNm " has no selector with the name " ++ show selNm
       in throwQ 'reifyRecordField issue
    Just ix -> do
      let par = TH.nameBase recNm
          sel = TH.nameBase selNm
          num = Proto3.FieldNumber (1 + fromIntegral @Int @Word64 ix)
       in TH.liftRecordField (RecordField par sel num)

selectorsOf :: Name -> Q [Name]
selectorsOf recNm = do
  [con] <- constructorsOf recNm
  case con of
    TH.RecC _ fields -> pure (namesOf fields)
    other -> throwMismatchCon other
  where
    namesOf :: [(Name, Bang, Type)] -> [Name]
    namesOf = map \(name, _, _) -> name

    throwMismatchCon :: Con -> Q a
    throwMismatchCon con =
      let expect = "expected " ++ TH.pprint recNm ++ " to be a record type"
          actual = "instead got " ++ TH.pprint con
       in throwQ 'selectorsOf (expect ++ ", " ++ actual)

constructorsOf :: Name -> Q [Con]
constructorsOf tynm = do
  dec <- reifyTyCon tynm
  case dec of
    TH.DataD _ _ _ _ cons _ -> pure cons
    TH.NewtypeD _ _ _ _ con _ -> pure [con]
    other -> throwMismatchDec other
  where
    throwMismatchDec :: Dec -> Q a
    throwMismatchDec dec =
      let expect = "expected " ++ TH.pprint tynm ++ " to be newtype or datatype"
          actual = "instead got " ++ TH.pprint dec
       in throwQ 'constructorsOf (expect ++ ", " ++ actual)

reifyTyCon :: Name -> Q Dec
reifyTyCon tynm = do
  info <- TH.reify tynm
  case info of
    TH.TyConI dec -> pure dec
    other -> throwMismatchInfo other
  where
    throwMismatchInfo :: Info -> Q a
    throwMismatchInfo info =
      let expect = "expected " ++ TH.pprint tynm ++ " to be a type"
          actual = "instead got " ++ TH.pprint info
       in throwQ 'reifyTyCon (expect ++ ", " ++ actual)

throwQ :: Name -> String -> Q a
throwQ nm msg = fail (shows nm " fail: " ++ msg)
