{-# LANGUAGE CPP #-}

{- | Generator for the Plinth submission artefacts on the @main@ branch
(Plinth 1.65.0.0). Selects production vs preview destination directory
via the @PREVIEW@ CPP define, which is set by the @preview@ cabal
flag (see @plinth-cape-submissions.cabal@). Each output path is
resolved relative to the UPLC-CAPE checkout pointed to by the
required @CAPE_REPO@ environment variable.
-}
module Main (main) where

import Prelude

import Cape.WritePlc (writeCodeToFile)
import Ecd (ecdCode)
import Factorial (factorialCode)
import Fibonacci (fibonacciCode)
import FibonacciIterative (fibonacciIterativeCode)
import HTLC (htlcValidatorCode)
import HTLC.Monadic qualified as Monadic
import LinearVesting (linearVestingValidatorCode)
import LinearVesting.AsData qualified as LvAsData
import PlutusTx.Code (CompiledCode)
import TwoPartyEscrow (twoPartyEscrowValidatorCode)

#ifdef PREVIEW
plinthVersion :: FilePath
plinthVersion = "Plinth_1.65.0.0_Unisay_preview"
#else
plinthVersion :: FilePath
plinthVersion = "Plinth_1.65.0.0_Unisay"
#endif

{- | Write a compiled program to
@$CAPE_REPO/submissions/<scenario>/<plinthVersion>[_<variant>]/<scenario>.uplc@.
'Nothing' writes the base submission; @'Just' v@ appends @_v@ to the
version directory for a variant submission. The artifact name is derived
from the scenario so it always matches the directory.
-}
write :: FilePath -> Maybe String -> CompiledCode a -> IO ()
write scenario variant =
  writeCodeToFile
    ( "submissions/"
        <> scenario
        <> "/"
        <> plinthVersion
        <> maybe "" ("_" <>) variant
        <> "/"
        <> scenario
        <> ".uplc"
    )

main :: IO ()
main = do
  write "ecd" Nothing ecdCode
  write "fibonacci_naive_recursion" Nothing fibonacciCode
  write "fibonacci" Nothing fibonacciIterativeCode
  write "factorial_naive_recursion" Nothing factorialCode
  write "linear_vesting" Nothing linearVestingValidatorCode
  write "linear_vesting" (Just "asdata") LvAsData.linearVestingValidatorCode
  write "htlc" Nothing htlcValidatorCode
  write "htlc" (Just "monadic") Monadic.htlcValidatorCode
  write "two_party_escrow" Nothing twoPartyEscrowValidatorCode
