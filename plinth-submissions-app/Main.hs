{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fplugin PlutusTx.Plugin #-}
{-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:target-version=1.1.0 #-}

-- | Generate the Plinth 1.45 submissions.
module Main (main) where

import Prelude

import Cape.WritePlc (writeCodeToFile)
import Ecd (ecdCode)
import Factorial (factorialCode)
import Fibonacci (fibonacciCode)
import FibonacciIterative (fibonacciIterativeCode)
import HTLC (htlcValidator)
import HTLC.Monadic qualified as Monadic
import LinearVesting (linearVestingValidator)
import LinearVesting.Monadic qualified as LvMonadic
import PlutusTx qualified
import PlutusTx.Builtins.Internal (BuiltinData)
import PlutusTx.Code (CompiledCode)
import PlutusTx.Prelude (BuiltinUnit)
import TwoPartyEscrow (twoPartyEscrowValidatorCode)
import TwoPartyEscrow.Monadic qualified as TpeMonadic

-- Keep these splices at the executable boundary to reproduce the published UPLC.
linearVestingValidatorCode :: CompiledCode (BuiltinData -> BuiltinUnit)
linearVestingValidatorCode = $$(PlutusTx.compile [||linearVestingValidator||])

htlcValidatorCode :: CompiledCode (BuiltinData -> BuiltinUnit)
htlcValidatorCode = $$(PlutusTx.compile [||htlcValidator||])

main :: IO ()
main = do
  writeCodeToFile
    "submissions/ecd/Plinth_1.45.0.0_Unisay/ecd.uplc"
    ecdCode
  writeCodeToFile
    "submissions/fibonacci_naive_recursion/Plinth_1.45.0.0_Unisay/fibonacci_naive_recursion.uplc"
    fibonacciCode
  writeCodeToFile
    "submissions/fibonacci/Plinth_1.45.0.0_Unisay/fibonacci.uplc"
    fibonacciIterativeCode
  writeCodeToFile
    "submissions/factorial_naive_recursion/Plinth_1.45.0.0_Unisay/factorial_naive_recursion.uplc"
    factorialCode
  writeCodeToFile
    "submissions/linear_vesting/Plinth_1.45.0.0_Unisay_plain/linear_vesting.uplc"
    linearVestingValidatorCode
  writeCodeToFile
    "submissions/linear_vesting/Plinth_1.45.0.0_Unisay/linear_vesting.uplc"
    LvMonadic.linearVestingValidatorCode
  writeCodeToFile
    "submissions/htlc/Plinth_1.45.0.0_Unisay_asdata/htlc.uplc"
    htlcValidatorCode
  writeCodeToFile
    "submissions/htlc/Plinth_1.45.0.0_Unisay/htlc.uplc"
    Monadic.htlcValidatorCode
  writeCodeToFile
    "submissions/two_party_escrow/Plinth_1.45.0.0_Unisay_plain/two_party_escrow.uplc"
    twoPartyEscrowValidatorCode
  writeCodeToFile
    "submissions/two_party_escrow/Plinth_1.45.0.0_Unisay/two_party_escrow.uplc"
    TpeMonadic.twoPartyEscrowValidatorCode
