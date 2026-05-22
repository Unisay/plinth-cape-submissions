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
{- Per-module Plinth inliner tuning. Selected by sweep over
inline-unconditional-growth × inline-callsite-growth (see
scripts/sweep-inline.sh): smallest uncond value reaching the deep
cpu_units.sum plateau (≈12.0% reduction). callsite stays at default
— for Ecd it can only reach a shallower plateau (≈2% reduction) and
adds nothing once uncond is tuned.

Sweep results (callsite=default, Plinth 1.64.0.0):

  uncond  cpu_units.sum  memory_units.sum  script_size  term_size
  ──────  ─────────────  ────────────────  ───────────  ─────────
  def       33 212 998         132 957             56         48
  44        33 212 998         132 957             56         48
  45 ◀      29 228 998         108 057            604        570
  50        29 228 998         108 057            642        607
  75        29 228 998         108 057            681        644
  1000      29 228 998         108 057            681        644

Sharp transition between uncond=44 and uncond=45: CPU drops 12.0% while
script grows ~10× in relative terms (still 604 bytes absolute). Above 45
the cpu plateau is flat; 45 is the leftmost point on it.
-}
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=45 #-}

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
