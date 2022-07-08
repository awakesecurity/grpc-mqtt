-- Copyright (c) 2022 Arista Networks, Inc.
-- Use of this source code is governed by the Apache License 2.0
-- that can be found in the COPYING file.
{-# LANGUAGE CPP #-}

-- | For versions of @proto3-suite@ starting with 0.5.0, merely
-- reexports `Proto3.Suite.DotProto.Internal.prefixedMethodName)`,
-- but for earlier versions emulates that function by defining it as
-- an alias of `Proto3.Suite.DotProto.Internal.prefixedFieldName`.
module Proto3.Suite.DotProto.Internal.Compat (prefixedMethodName) where

#if MIN_VERSION_proto3_suite(0,5,0)

import Proto3.Suite.DotProto.Internal (prefixedMethodName)

#else

import Proto3.Suite.DotProto.Internal (prefixedFieldName)

prefixedMethodName :: MonadError CompileError m => String -> String -> m String
prefixedMethodName = prefixedFieldName

#endif
