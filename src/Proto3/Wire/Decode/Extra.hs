{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | Extensions to the proto-wire format decoders missing from the proto3-wire
-- package.
--
-- @since 1.0.0
module Proto3.Wire.Decode.Extra
  ( -- * Message Parsers
    msgOneField,

    -- * Field Parsers
    oneField,

    -- * Primitive Parsers
    primOneField,
    primOptField,
    sint,

    -- * Parse Error
    wireErrorLabel,

    -- * Parse Error Handling
    throwE,
    catchE,
  )
where

---------------------------------------------------------------------------------

import Data.Int (Int64)

import Data.Text.Lazy qualified as Lazy.Text

import Language.Haskell.TH (Name)

import Proto3.Wire.Decode (ParseError, Parser, RawField, RawMessage, RawPrimitive)
import Proto3.Wire.Decode qualified as Decode

---------------------------------------------------------------------------------

import Proto3.Wire.Types.Extra (RecordField (recFieldNumber))

-- Message Parsers --------------------------------------------------------------

msgOneField :: RecordField -> Parser RawField a -> Parser RawMessage a
msgOneField recField parse =
  catchE
    (Decode.at parse (recFieldNumber recField))
    (throwE . wireErrorRecordField recField)

-- Field Parsers ----------------------------------------------------------------

-- | Constructs a required record field parser from a 'RecordField' outlining the
-- field being parsed and the field's 'RawPrimitive' parser.
--
-- * Throws a parse error if the record field is missing.
--
-- * Thrown parse errors are annotated with the field number, field selector,
--   and parent record.
--
-- @since 1.0.0
oneField :: RecordField -> Parser RawPrimitive a -> Parser RawField a
oneField recField parse = do
  fieldM <- Decode.one (fmap Just parse) Nothing
  case fieldM of
    Nothing -> onMissingField
    Just fx -> pure fx
  where
    onMissingField :: Parser RawField a
    onMissingField =
      let err :: ParseError
          err = Decode.BinaryError "missing required field"
       in throwE (wireErrorRecordField recField err)

-- Primtiive Parsers ------------------------------------------------------------

primOneField :: RecordField -> Parser RawPrimitive a -> Parser RawMessage a
primOneField recField = msgOneField recField . oneField recField

-- | Constructs an optional record field parser from a 'RecordField' outlining
-- the field being parsed, the field's 'RawPrimitive' parser, and a default
-- value to use if the field is missing.
--
--   * Thown parse errors are annotated with the field number, field selector,
--     and parent record.
--
-- @since 1.0.0
primOptField :: RecordField -> Parser RawPrimitive a -> a -> Parser RawMessage a
primOptField recField parse def = msgOneField recField (Decode.one parse def)

-- | Parses an 'Int' primitive encoded as a fixed-width 64-bit integer.
--
-- @since 1.0.0
sint :: Parser RawPrimitive Int
sint =
  let parse :: Parser RawPrimitive Int
      parse = fmap (fromIntegral @Int64 @Int) Decode.sint64
   in catchE parse (throwE . wireErrorLabel 'sint)

---------------------------------------------------------------------------------

-- | Takes a parse error @e@, a 'RecordField' type, and returns a new
-- 'ParseError' annotating @e@ with:
--
--   * the field number of the field being parsed
--
--   * the name of the record field selector being parsed
--
--   * the name of the 'RecordField' parent record the parsed field is
--     constructing
--
-- @since 1.0.0
wireErrorRecordField :: RecordField -> ParseError -> ParseError
wireErrorRecordField recField e =
  let issue :: String
      issue = "decoding " ++ show recField ++ " raised"
   in Decode.EmbeddedError (Lazy.Text.pack issue) (Just e)

-- | Takes a parse error @e@, and the name of the enclosing parser. Returns a new
-- 'ParseError' annotating @e@ with a qualified name.
--
-- 'wireErrorLabel' can be used to annotate errors intercepted by atomic parsers
-- with name information to distinguish ambiguous parse errors.
--
-- >>> runParser sint (Fixed32Field "bad!")
-- Left (EmbeddedError "decoding Proto3.Wire.Decode.Extra.sint raised" e)
--
-- @since 1.0.0
wireErrorLabel :: Name -> ParseError -> ParseError
wireErrorLabel nm e =
  let issue :: String
      issue = "decoding " ++ show nm ++ " raised"
   in Decode.EmbeddedError (Lazy.Text.pack issue) (Just e)

---------------------------------------------------------------------------------

-- | Raise a wire-format parse error.
--
-- @since 1.0.0
throwE :: ParseError -> Parser i a
throwE e = Decode.Parser \_ -> Left e
{-# INLINE throwE #-}

-- | Catch and handle parse errors by a parser.
--
-- @since 1.0.0
catchE :: Parser i a -> (ParseError -> Parser i a) -> Parser i a
catchE parse onError =
  Decode.Parser \input ->
    case Decode.runParser parse input of
      Left err -> Decode.runParser (onError err) input
      Right dx -> pure dx
{-# INLINE catchE #-}
