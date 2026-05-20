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

module Factorial (factorialCode, factorial) where

import PlutusTx
import PlutusTx.Prelude

-- | Compiled factorial function
factorialCode :: CompiledCode (Integer -> Integer)
factorialCode = $$(PlutusTx.compile [||factorial||])

{-# INLINEABLE factorial #-}
factorial :: Integer -> Integer
factorial n
  | n <= 0 = 1
  | otherwise = n * factorial (n - 1)
