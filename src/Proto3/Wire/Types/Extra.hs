{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE ImplicitPrelude #-}

-- | Type declarations extending the proto3-wire package.
--
-- @since 0.1.0.0
module Proto3.Wire.Types.Extra
  ( -- * RecordField
    RecordField
      ( RecordField,
        recFieldParent,
        recFieldSelect,
        recFieldNumber
      ),
  )
where

---------------------------------------------------------------------------------

import Proto3.Wire (FieldNumber)

---------------------------------------------------------------------------------

-- | 'RecordField' is a information on a record field represented by the name of
-- the record type containing the field, the name of the field, and a compatible
-- 'FieldNumber' indexing the record field.
--
-- @since 0.1.0.0
data RecordField = RecordField
  { -- | The name of a record type containing the record field, obtained by a
    -- template haskell quote:
    --
    -- prop> recFieldParent ~ nameBase 'MyRecordType
    recFieldParent :: String
  , -- | The name of the record field, obtained by a template haskell quote:
    --
    -- prop> recFieldSelect ~ nameBase 'myRecordField
    recFieldSelect :: String
  , -- | Proto compatible 'FieldNumber' indexing this record field. The first
    -- field in a record is assigned @'FieldNumber' 1@.
    recFieldNumber :: {-# UNPACK #-} !FieldNumber
  }

-- | @since 0.1.0.0
instance Show RecordField where
  show (RecordField par sel num) =
    "field #"
      ++ shows num " "
      ++ shows sel " of record "
      ++ show par
  {-# INLINE show #-}
