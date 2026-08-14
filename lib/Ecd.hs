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

{- Per-module Plinth inliner tuning: NONE. The plugin defaults
(inline-unconditional-growth=1, inline-callsite-growth=5) sit on the
optimal plateau for the CAPE objective, so this module sets no pragma.

Swept 1-D on uncond against total_fee_lovelace (plutus 1.67, measured on
CAPE's 1.63 production evaluator, scripts/sweep-inline.sh):

  uncond       total_fee  exec   refscript  cpu_units.sum  script_size
  ───────────  ─────────  ─────  ─────────  ─────────────  ───────────
  1 (dflt)–27      7 886  7 196        690     22 731 572           46
  32              12 162  5 472      6 690     18 747 572          446
  40–48           13 002  5 472      7 530     18 747 572          502

This module used to carry uncond=45, and it is the one place in this tree
where the old choice came from ranking on cpu_units.sum alone rather than
on fee. Crossing from 27 to 32 unrolls the recursion, buying 3 984 000 CPU
steps for 400 bytes of script. Since Conway charges the reference script on
every referencing transaction, one byte costs 208 044 CPU steps at mainnet
parameters, so that trade needed roughly 83 000 000 steps to break even —
short by a factor of 21. Ranking the same axis by fee drops the pragma and
takes ecd from 13 002 to 7 886 lovelace, −39%.

Size dominates the fee here, which is why the axis mattered so much: at
uncond=45 the reference-script fee is 7 530 of the 13 002 total (58%),
against 690 of 7 886 (9%) at default.

The per-execution exception does not rescue uncond=45. Inlining saves
1 724 lovelace of execution across the 14 measurement cases, i.e. ~123 per
execution, against 6 840 of extra reference-script fee charged once per
transaction — so it needs about 56 executions of this script in a single
transaction to break even, against the 14 the measurement models.

Re-sweep after structural changes, and on every plutus bump. The 1.64
table's absolute sizes did not carry to 1.67 (604 → 502 bytes at uncond=45),
which is why this win was over-predicted at −51% before being measured.
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
