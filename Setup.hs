-- See the comments for 'ppProto'.

{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -Wall #-}

import Distribution.Simple
         (UserHooks(..), defaultMainWithHooks, simpleUserHooks)
import Distribution.Simple.PreProcess (PreProcessor(..))
import Distribution.Simple.Program (runProgram, simpleProgram)
import Distribution.Simple.Program.Db (requireProgram)
import Distribution.Simple.Program.Types (Program(..))
import Distribution.Simple.Utils (info)
import Distribution.Types.BuildInfo (BuildInfo)
import Distribution.Types.LocalBuildInfo (LocalBuildInfo(..))
import Distribution.Types.ComponentLocalBuildInfo (ComponentLocalBuildInfo)
import Distribution.Verbosity (Verbosity)
import Data.Maybe (fromMaybe)
import Data.List qualified as List
import System.FilePath ((</>), normalise)
import System.Environment qualified as System

#if MIN_VERSION_Cabal(3,8,0)
import Distribution.Simple.PreProcess (unsorted)
#endif

main :: IO ()
main = do 
  args <- System.getArgs 

  let protoInDir :: Maybe String 
      protoInDir = argProtoPath args 

  defaultMainWithHooks (customHooks protoInDir)

argProtoPath :: [String] -> Maybe FilePath
argProtoPath [] = Nothing
argProtoPath (arg : args) 
  | argName `List.isPrefixOf` arg = pure (drop (length argName) arg)
  | otherwise = argProtoPath args 
  where 
    argName :: String
    argName = "--includeDir"

customHooks :: Maybe FilePath -> UserHooks
customHooks protoInDir = simpleUserHooks
  { hookedPreProcessors =
      ( "proto", ppProto protoInDir ) : hookedPreProcessors simpleUserHooks
  }

-- | Converts a MyModule.proto to MyModule.hs using compile-proto-file,
-- though of necessity MyModule.proto departs from the usual naming
-- conventions for .proto files.  Cabal does not seem to support
-- a rename during a preprocessing; therefore the package name present
-- in MyModule.proto MUST trigger the choice of MyModule.hs for the
-- generated module name, according to the rules of compile-proto-file.
--
-- For these reasons this hook is intended only for local use
-- in this package.  It is NOT recommended for broader use.
--
-- (An alternative design might be to mention the actual .proto name
-- in MyModule.proto, but then we might have to use some special Cabal
-- feature to broaden the dependencies of MyModule.hs to include that file.
-- In fact, such dependency analysis might help with the import of
-- message.proto by service.proto in the tests.)
ppProto ::
  Maybe FilePath ->
  BuildInfo ->
  LocalBuildInfo ->
  ComponentLocalBuildInfo ->
  PreProcessor
ppProto protoInDir _buildInfo localBuildInfo _componentLocalBuildInfo = PreProcessor
  { platformIndependent = True
  , runPreProcessor = genProto protoInDir localBuildInfo
#if MIN_VERSION_Cabal(3,8,0)
  , ppOrdering = unsorted
#endif
  }

genProto ::
  Maybe FilePath ->
  LocalBuildInfo ->
  (FilePath, FilePath) ->
  (FilePath, FilePath) ->
  Verbosity ->
  IO ()
genProto protoInDir localBuildInfo (inBaseDir, inRelativeFile)
         (outBaseDir, outRelativeFile) verbosity = do
  let inFile = normalise (inBaseDir </> inRelativeFile)
      outFile = normalise (outBaseDir </> outRelativeFile)
  info verbosity $ "compiling " ++ show inFile ++ " to " ++ show outFile
  (cpfProg, _) <-
    requireProgram verbosity cpfProgram (withPrograms localBuildInfo)
  let extraArgs =
        [ "--includeDir"
        , fromMaybe inBaseDir protoInDir
        , "--out"
        , outBaseDir
        , "--proto"
        , inRelativeFile
        ]
  runProgram verbosity cpfProg extraArgs

cpfProgram :: Program
cpfProgram = simpleProgram "compile-proto-file"
