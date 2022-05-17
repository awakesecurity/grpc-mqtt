{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | Template haskell extensions to type exported by the proto3-wire package.
--
-- @since 1.0.0
module Proto3.Wire.Types.Extra.TH
  ( -- * Template Haskell Extensions
    liftFieldNumber,
    liftRecordField,
  )
where

---------------------------------------------------------------------------------

import Language.Haskell.TH (Q)
import Language.Haskell.TH.Syntax (Exp (AppE, ConE), lift)

import Proto3.Suite (FieldNumber (FieldNumber))

---------------------------------------------------------------------------------

import Proto3.Wire.Types.Extra (RecordField (RecordField))

---------------------------------------------------------------------------------

-- | Lifts a 'FieldNumber' type into a quoted expression.
--
-- @since 1.0.0
liftFieldNumber :: FieldNumber -> Q Exp
liftFieldNumber (FieldNumber x) = do
  litE <- lift x
  let conE :: Exp
      conE = ConE 'FieldNumber
   in pure (conE `AppE` litE)

-- | Lifts a 'RecordField' type into a quoted expression.
--
-- @since 1.0.0
liftRecordField :: RecordField -> Q Exp
liftRecordField (RecordField par sel num) = do
  parE <- lift par
  selE <- lift sel
  numE <- liftFieldNumber num
  pure (ConE 'RecordField `AppE` parE `AppE` selE `AppE` numE)
