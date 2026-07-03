{-# LANGUAGE NoImplicitPrelude #-}
--
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}

{- |
A zero-cost typed view of encoded (still-'BuiltinData') values, against
BuiltinData-blindness: @'Encoded' Redeemer@ tells the reader (and the type
checker) what a raw value IS, while costing exactly nothing — the wrapper is a
newtype, equality is 'equalsData' on the raw bytes, and 'decode' marks the one
place a structural decode actually happens.

The list combinators walk an @'Encoded' (List a)@ handing the loop body
'Encoded' ELEMENTS — no per-element decode unless the body asks for one.
-}
module Plinth.Encoded (
  Encoded (Encoded),
  encoded,
  decode,
  tagOf,

  -- * Loops over encoded lists
  anyE,
  findE,
  countE,

  -- * Lookup in encoded maps
  lookupE,
) where

import PlutusTx.AsData.Internal (wrapUnsafeDataAsConstr)
import PlutusTx.Builtins (BuiltinString, equalsData, matchList, matchList')
import PlutusTx.Builtins.Internal (BuiltinData, BuiltinInteger)
import PlutusTx.Builtins.Internal qualified as BI
import PlutusTx.Data.AssocMap (Map)
import PlutusTx.Data.List (List)
import PlutusTx.Eq qualified as PlutusTx
import PlutusTx.IsData.Class (
  ToData,
  UnsafeFromData,
  toBuiltinData,
  unsafeFromBuiltinData,
 )
import PlutusTx.Prelude (Bool (False, True), Integer, traceError, (+))

-- | A raw 'BuiltinData' value known (claimed) to be the encoding of an @a@.
newtype Encoded a = Encoded BuiltinData

-- | Equality of the raw encodings: one 'equalsData', no decode.
instance PlutusTx.Eq (Encoded a) where
  Encoded x == Encoded y = equalsData x y
  {-# INLINE (==) #-}

-- | Forget a (data-backed) value's type: a free coerce for @asData@ types.
encoded :: ToData a => a -> Encoded a
encoded = Encoded `dot` toBuiltinData
  where
    dot f g x = f (g x)
    {-# INLINE dot #-}
{-# INLINE encoded #-}

-- | The one place a structural decode happens.
decode :: UnsafeFromData a => Encoded a -> a
decode (Encoded d) = unsafeFromBuiltinData d
{-# INLINE decode #-}

{- | The constructor tag of an encoded sum value (e.g. @0@ for
@PubKeyCredential@). One @unConstrData@; no fields are touched.
-}
tagOf :: Encoded a -> BuiltinInteger
tagOf (Encoded d) = BI.fst (wrapUnsafeDataAsConstr d)
{-# INLINE tagOf #-}

--------------------------------------------------------------------------------
-- Loops over encoded lists ---------------------------------------------------

-- | Whether any element satisfies the predicate; stops at the first hit.
anyE :: (Encoded a -> Bool) -> Encoded (List a) -> Bool
anyE p (Encoded d) = go (BI.unsafeDataAsList d)
  where
    go xs = matchList' xs False \h t ->
      if p (Encoded h) then True else go t
{-# INLINEABLE anyE #-}

{- | The first element satisfying the predicate; aborts with the message when
there is none.
-}
findE :: BuiltinString -> (Encoded a -> Bool) -> Encoded (List a) -> Encoded a
findE msg p (Encoded d) = go (BI.unsafeDataAsList d)
  where
    go xs = matchList xs (\_ -> traceError msg) \h t ->
      if p (Encoded h) then Encoded h else go t
{-# INLINEABLE findE #-}

-- | How many elements satisfy the predicate.
countE :: (Encoded a -> Bool) -> Encoded (List a) -> Integer
countE p (Encoded d) = go 0 (BI.unsafeDataAsList d)
  where
    go acc xs = matchList' xs acc \h t ->
      go (if p (Encoded h) then acc + 1 else acc) t
{-# INLINEABLE countE #-}

--------------------------------------------------------------------------------
-- Lookup in encoded maps -------------------------------------------------------

{- | Look up a key in an encoded map: one 'equalsData' per entry, no decode.
Continuation-passing instead of 'Maybe', so no sum value ever materialises:
@missing@ is returned when the key is absent, otherwise @found@ receives the
value still 'Encoded'.
-}
lookupE :: Encoded k -> r -> (Encoded v -> r) -> Encoded (Map k v) -> r
lookupE (Encoded k) missing found (Encoded d) = go (BI.unsafeDataAsMap d)
  where
    go xs = matchList' xs missing \h t ->
      if equalsData k (BI.fst h) then found (Encoded (BI.snd h)) else go t
{-# INLINEABLE lookupE #-}
