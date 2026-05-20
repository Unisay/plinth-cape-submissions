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

module Fibonacci (fibonacciCode, fibonacci) where

import PlutusTx
import PlutusTx.Prelude

-- | Compiled fibonacci function
fibonacciCode :: CompiledCode (Integer -> Integer)
fibonacciCode = $$(PlutusTx.compile [||fibonacci||])

{-# INLINEABLE fibonacci #-}
fibonacci :: Integer -> Integer
fibonacci n
  | n <= 1 = n
  | otherwise = fibonacci (n - 1) + fibonacci (n - 2)
