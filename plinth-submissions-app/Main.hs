{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}

{- | Generator for the Plinth submission artefacts on the @main@ branch
(Plinth 1.64.0.0). Selects production vs preview destination directory
via the @PREVIEW@ CPP define, which is set by the @preview@ cabal
flag (see @plinth-cape-submissions.cabal@). Each output path is
resolved relative to the sibling UPLC-CAPE checkout — set @CAPE_REPO@
if it is not at @../UPLC-CAPE@.
-}
module Main (main) where

import Prelude

import Cape.WritePlc (writeCodeToFile)
import Ecd (ecdCode)
import Factorial (factorialCode)
import Fibonacci (fibonacciCode)
import FibonacciIterative (fibonacciIterativeCode)
import HTLC (htlcValidator)
import LinearVesting (linearVestingValidator)
import PlutusTx qualified
import PlutusTx.Builtins.Internal (BuiltinData)
import PlutusTx.Code (CompiledCode)
import PlutusTx.Prelude (BuiltinUnit)
import TwoPartyEscrow (twoPartyEscrowValidatorCode)

#ifdef PREVIEW
plinthVersion :: FilePath
plinthVersion = "Plinth_1.64.0.0-builtin-casing_Unisay"
#else
plinthVersion :: FilePath
plinthVersion = "Plinth_1.64.0.0_Unisay"
#endif

-- Compile splices live here (not in HTLC.hs / LinearVesting.hs) as a
-- workaround for a PlutusTx plugin interaction observed under the
-- 1.45 line; kept in place pending verification on 1.64.
linearVestingValidatorCode :: CompiledCode (BuiltinData -> BuiltinUnit)
linearVestingValidatorCode = $$(PlutusTx.compile [||linearVestingValidator||])

htlcValidatorCode :: CompiledCode (BuiltinData -> BuiltinUnit)
htlcValidatorCode = $$(PlutusTx.compile [||htlcValidator||])

write :: FilePath -> FilePath -> CompiledCode a -> IO ()
write scenario file =
  writeCodeToFile ("submissions/" <> scenario <> "/" <> plinthVersion <> "/" <> file)

main :: IO ()
main = do
  write "ecd" "ecd.uplc" ecdCode
  write "fibonacci_naive_recursion" "fibonacci.uplc" fibonacciCode
  write "fibonacci" "fibonacci.uplc" fibonacciIterativeCode
  write "factorial_naive_recursion" "factorial.uplc" factorialCode
  write "linear_vesting" "linear_vesting.uplc" linearVestingValidatorCode
  write "htlc" "htlc.uplc" htlcValidatorCode
  write "two_party_escrow" "two_party_escrow.uplc" twoPartyEscrowValidatorCode
