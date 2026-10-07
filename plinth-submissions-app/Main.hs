{- | Generator for the Plinth submission artefacts on the @main@ branch
(Plinth 1.71.0.0). Each output path is resolved relative to the UPLC-CAPE
checkout pointed to by the required @CAPE_REPO@ environment variable.
-}
module Main (main) where

import Prelude

import Cape.WritePlc (writeCodeToFile)
import Ecd (ecdCode)
import Factorial (factorialCode)
import Fibonacci (fibonacciCode)
import FibonacciIterative (fibonacciIterativeCode)
import HTLC (htlcValidatorCode)
import LinearVesting (linearVestingValidatorCode)
import PlutusTx.Code (CompiledCode)
import TwoPartyEscrow (twoPartyEscrowValidatorCode)

plinthVersion :: FilePath
plinthVersion = "Plinth_1.71.0.0_Unisay"

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

{- | Write every submission. The asdata variants are not written: under 1.71
the derived 'unsafeFromBuiltinData' of a sum type compiles to @case@ on Data,
which needs Plutus Core 1.2.0 even with @target-version=1.1.0@.
-}
main :: IO ()
main = do
  write "ecd" Nothing ecdCode
  write "fibonacci_naive_recursion" Nothing fibonacciCode
  write "fibonacci" Nothing fibonacciIterativeCode
  write "factorial_naive_recursion" Nothing factorialCode
  write "linear_vesting" Nothing linearVestingValidatorCode
  write "htlc" Nothing htlcValidatorCode
  write "two_party_escrow" Nothing twoPartyEscrowValidatorCode
