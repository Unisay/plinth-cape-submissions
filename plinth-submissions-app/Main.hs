-- | Generate the Plinth 1.61 submissions with BuiltinCasing.
module Main (main) where

import Prelude

import Cape.WritePlc (writeCodeToFile)
import Compiled.Ecd (ecdCode)
import Compiled.Factorial (factorialCode)
import Compiled.Fibonacci (fibonacciCode)
import Compiled.FibonacciIterative (fibonacciIterativeCode)
import Compiled.HTLC (htlcValidatorCode)
import Compiled.LinearVesting (linearVestingValidatorCode)
import Compiled.TwoPartyEscrow (twoPartyEscrowValidatorCode)

main :: IO ()
main = do
  writeCodeToFile
    "submissions/ecd/Plinth_1.61.0.0_Unisay/ecd.uplc"
    ecdCode
  writeCodeToFile
    "submissions/fibonacci_naive_recursion/Plinth_1.61.0.0_Unisay/fibonacci_naive_recursion.uplc"
    fibonacciCode
  writeCodeToFile
    "submissions/fibonacci/Plinth_1.61.0.0_Unisay/fibonacci.uplc"
    fibonacciIterativeCode
  writeCodeToFile
    "submissions/factorial_naive_recursion/Plinth_1.61.0.0_Unisay/factorial_naive_recursion.uplc"
    factorialCode
  writeCodeToFile
    "submissions/linear_vesting/Plinth_1.61.0.0_Unisay/linear_vesting.uplc"
    linearVestingValidatorCode
  writeCodeToFile
    "submissions/htlc/Plinth_1.61.0.0_Unisay/htlc.uplc"
    htlcValidatorCode
  writeCodeToFile
    "submissions/two_party_escrow/Plinth_1.61.0.0_Unisay/two_party_escrow.uplc"
    twoPartyEscrowValidatorCode
