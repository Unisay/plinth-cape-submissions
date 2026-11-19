{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Monad.Except (runExceptT)
import qualified Data.Text.IO as Text
import PlutusCore.Error (FreeVariableError, ParserErrorBundle)
import PlutusCore.Quote (runQuote)
import System.Environment (getArgs)
import System.Exit (die)
import qualified UntypedPlutusCore as UPLC
import UntypedPlutusCore.DeBruijn (deBruijnTerm)
import qualified UntypedPlutusCore.Parser as Parser

main :: IO ()
main = getArgs >>= mapM_ validate

validate :: FilePath -> IO ()
validate path = do
  source <- Text.readFile path
  let parsed = runQuote (runExceptT (Parser.parse Parser.program path source))
  program <- either (die . show @ParserErrorBundle) pure parsed
  case deBruijnTerm (UPLC._progTerm program) of
    Left err -> die (path ++ ": " ++ show @FreeVariableError err)
    Right _ -> pure ()
