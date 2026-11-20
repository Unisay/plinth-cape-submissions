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
import HTLC.Monadic qualified as Monadic
import LinearVesting.Monadic qualified as LvMonadic
import TwoPartyEscrow.Monadic qualified as TpeMonadic
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
        <> "Plinth_1.64.0.0_Unisay"
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
  write "linear_vesting" (Just "plain") linearVestingValidatorCode
  write "htlc" (Just "asdata") htlcValidatorCode
  write "two_party_escrow" (Just "plain") twoPartyEscrowValidatorCode
#else
  write "linear_vesting" Nothing LvMonadic.linearVestingValidatorCode
  write "htlc" Nothing Monadic.htlcValidatorCode
  write "two_party_escrow" Nothing TpeMonadic.twoPartyEscrowValidatorCode
#endif
