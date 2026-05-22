{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}

{- | Generator for the Plinth submission artefacts on the @main@ branch
(Plinth 1.64.0.0). Selects production vs preview destination directory
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
import LinearVesting (linearVestingValidator)
import PlutusTx qualified
import PlutusTx.Builtins.Internal (BuiltinData)
import PlutusTx.Code (CompiledCode)
import PlutusTx.Prelude (BuiltinUnit)
import TwoPartyEscrow (twoPartyEscrowValidatorCode)

#ifdef PREVIEW
plinthVersion :: FilePath
plinthVersion = "Plinth_1.64.0.0_Unisay_builtincasing"
#else
plinthVersion :: FilePath
plinthVersion = "Plinth_1.64.0.0_Unisay"
#endif

-- LinearVesting splice still lives here (workaround for a PlutusTx plugin
-- interaction observed under the 1.45 line, pending verification on 1.64).
-- HTLC splice was moved back into HTLC.hs so per-module OPTIONS_GHC pragmas
-- reach its plugin invocation.
linearVestingValidatorCode :: CompiledCode (BuiltinData -> BuiltinUnit)
linearVestingValidatorCode = $$(PlutusTx.compile [||linearVestingValidator||])

-- | Write a compiled program to
-- @$CAPE_REPO/submissions/<scenario>/<plinthVersion>/<scenario>.uplc@.
-- The artifact name is derived from the scenario so it always matches
-- the directory.
write :: FilePath -> CompiledCode a -> IO ()
write scenario =
  writeCodeToFile ("submissions/" <> scenario <> "/" <> plinthVersion <> "/" <> scenario <> ".uplc")

main :: IO ()
main = do
  write "ecd" ecdCode
  write "fibonacci_naive_recursion" fibonacciCode
  write "fibonacci" fibonacciIterativeCode
  write "factorial_naive_recursion" factorialCode
  write "linear_vesting" linearVestingValidatorCode
  write "htlc" htlcValidatorCode
  write "two_party_escrow" twoPartyEscrowValidatorCode
