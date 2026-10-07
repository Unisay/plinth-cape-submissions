{-# LANGUAGE Strict #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}
--
{-# OPTIONS_GHC -fno-full-laziness #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-spec-constr #-}
{-# OPTIONS_GHC -fno-specialise #-}
{-# OPTIONS_GHC -fno-strictness #-}
{-# OPTIONS_GHC -fno-unbox-small-strict-fields #-}
{-# OPTIONS_GHC -fno-unbox-strict-fields #-}

{- Inliner budgets: none. Under plutus 1.71 every swept cell with uncond up to
28 and callsite from 5 to 28 costs the same 7 886 total_fee_lovelace (CAPE's
1.63 evaluator). uncond 32 unrolls the recursion and costs 12 162: it saves
CPU but adds 400 bytes, and size dominates this script's fee.
-}

module Ecd (ecdCode, ecd) where

import PlutusTx
import PlutusTx.Prelude

-- | Compiled ECD (Euclidean Common Divisor) function
ecdCode :: CompiledCode (Integer -> Integer -> Integer)
ecdCode = $$(PlutusTx.compile [||ecd||])

{-# INLINEABLE ecd #-}
ecd :: Integer -> Integer -> Integer
ecd a b
  | b == 0 = abs a
  | otherwise = ecd b (a `modulo` b)
