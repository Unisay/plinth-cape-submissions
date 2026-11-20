{-# LANGUAGE CPP #-}

-- | Generate the published CAPE rows supplied by this build.
module Main (main) where

import Prelude

import Cape.WritePlc (writeCodeToFile)
import PlutusTx.Code (CompiledCode)
#ifdef BUILTIN_CASING
import Ecd (ecdCode)
import Factorial (factorialCode)
import Fibonacci (fibonacciCode)
import FibonacciIterative (fibonacciIterativeCode)
import HTLC (htlcValidatorCode)
import LinearVesting (linearVestingValidatorCode)
import TwoPartyEscrow (twoPartyEscrowValidatorCode)
#else
import HTLC.AsData qualified as HtlcAsData
import LinearVesting.AsData qualified as LvAsData
import TwoPartyEscrow.AsData qualified as TpeAsData
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
        <> "Plinth_1.65.0.0_Unisay"
        <> maybe "" ("_" <>) variant
        <> "/"
        <> scenario
        <> ".uplc"
    )

main :: IO ()
main = do
#ifdef BUILTIN_CASING
  write "ecd" Nothing ecdCode
  write "fibonacci_naive_recursion" Nothing fibonacciCode
  write "fibonacci" Nothing fibonacciIterativeCode
  write "factorial_naive_recursion" Nothing factorialCode
  write "linear_vesting" Nothing linearVestingValidatorCode
  write "htlc" Nothing htlcValidatorCode
  write "two_party_escrow" Nothing twoPartyEscrowValidatorCode
#else
  write "linear_vesting" (Just "plain") LvAsData.linearVestingValidatorCode
  write "htlc" (Just "asdata") HtlcAsData.htlcValidatorCode
  write "two_party_escrow" (Just "asdata") TpeAsData.twoPartyEscrowValidatorCode
#endif
