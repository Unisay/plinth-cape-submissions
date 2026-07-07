{-# LANGUAGE NoImplicitPrelude #-}
--
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}

{- |
A zero-cost streaming decoder for a single @Constr@ spine walk: a @Cont@-style
monad ("Plinth.Validator") extended with a cursor — the not-yet-consumed tail
of the @Constr@ args. Sequencing a decoder program is walking the spine; one
'walking' region performs exactly ONE walk by construction, instead of relying
on CSE to merge repeated walks. See Note [Streaming decoder].

The steps here are POSITIONAL (@skip@/'fieldRaw' move a cursor blindly); for
the by-name, type-checked layer that compiles down to them, see
"Plinth.Decoder.Named".
-}
module Plinth.Decoder (
  Decoder (Decoder),
  bindDecoder,
  thenDecoder,
  pureDecoder,
  fieldRaw,
  skip,
  skips,
  guardHere,
  walking,
) where

import Plinth.Validator (Validator (Validator))
import PlutusTx.AsData.Internal (wrapTail, wrapUnsafeDataAsConstr)
import PlutusTx.Builtins.Internal (BuiltinData, BuiltinList, BuiltinUnit)
import PlutusTx.Builtins.Internal qualified as BI
import PlutusTx.Prelude (Bool (False, True), BuiltinString, Integer, traceError)

{- Note [Streaming decoder]
'Decoder' is the state-continuation composition @s -> (a -> s -> r) -> r@
specialised to @s@ = the remaining @Constr@ args ('BuiltinList' 'BuiltinData')
and @r@ = 'BuiltinUnit' (the 'Validator' answer type, so aborts can happen
mid-walk via 'guardHere').

Two properties carry the zero-cost claim:

  * the cursor is threaded as a LAMBDA ARGUMENT of each continuation, so it is
    a shared, already-evaluated value under call-by-value — never a
    re-forceable @delay@. (The CEK machine does not memoise @force (delay …)@,
    so a delayed decode prefix re-runs on every force — an abort path would
    pay it twice.)
  * 'fieldRaw' returns the field RAW; grabbing a field "out of demand order"
    while the walk passes it costs one @headList@, and the structural decode
    stays at the use site. This is what makes a single monotone walk compatible
    with non-monotone demand (e.g. the inputs list is spine index 0 but is only
    needed by the LAST guard: grab raw early, decode late).

The steps build on the raw builtins ('BI.head', wrapped @unConstrData@ /
@tailList@): the high-level @unsafeDataAsConstr@ would materialise the Constr
args as a Haskell list — a full spine fold before the first field is read.

The cursor rests ON the field 'fieldRaw' just read (advancing is always an
explicit 'skip'), so a region's last read leaves no dead trailing @tailList@
by construction. 'skip' uses 'wrapTail' (not 'BI.tail') to keep the
advancing steps recognisable to the Plinth plugin as droppable-when-dead.
-}

-- | A decoder over one @Constr@ spine, parameterised over its continuation.
newtype Decoder a
  = Decoder
      ( BuiltinList BuiltinData ->
        (a -> BuiltinList BuiltinData -> BuiltinUnit) ->
        BuiltinUnit
      )

infixr 1 `bindDecoder`

infixr 1 `thenDecoder`

-- | Monadic bind: thread the value and the cursor into the next decoder.
{-# INLINE bindDecoder #-}
bindDecoder :: Decoder a -> (a -> Decoder b) -> Decoder b
bindDecoder (Decoder m) f = Decoder \s k ->
  m s \a s' -> case f a of Decoder n -> n s' k

-- | Sequence two decoders, discarding the first's result.
{-# INLINE thenDecoder #-}
thenDecoder :: Decoder a -> Decoder b -> Decoder b
thenDecoder (Decoder m) (Decoder n) = Decoder \s k -> m s \_ s' -> n s' k

-- | Yield a value without moving the cursor.
{-# INLINE pureDecoder #-}
pureDecoder :: a -> Decoder a
pureDecoder a = Decoder \s k -> k a s

{- | The raw field under the cursor. The cursor does NOT advance: it rests on
the field just read, and moving on is always an explicit 'skip' (which the
by-name layer generates from the next field's gap). This way a region's last
read never computes a dead trailing @tailList@ — by construction, not by
choosing a special final combinator.
-}
{-# INLINE fieldRaw #-}
fieldRaw :: Decoder BuiltinData
fieldRaw = Decoder \s k -> k (BI.head s) s

-- | Advance the cursor one field.
{-# INLINE skip #-}
skip :: Decoder ()
skip = Decoder \s k -> k () (wrapTail s)

{- | Advance the cursor @n@ fields in ONE @dropList@ call. @dropList@ is a
batch-6 builtin (PlutusV3 from the van Rossem protocol version), so this
step is only emitted by the PREVIEW build of "Plinth.Decoder.Named"; the
production build unrolls the gap into 'skip' steps instead. Measured
against @tailList@ chains (see Note [Emitting dropList for wide gaps] in
"Plinth.Decoder.Named"): one call wins on cpu from a 2-field gap and on
total fee from a 3-field gap.
-}
{-# INLINE skips #-}
skips :: Integer -> Decoder ()
skips n = Decoder \s k -> k () (BI.drop n s)

-- | A boolean guard in the middle of a walk: continue, or abort the script.
{-# INLINE guardHere #-}
guardHere :: BuiltinString -> Bool -> Decoder ()
guardHere msg cond = Decoder \s k -> case cond of
  True -> k () s
  False -> traceError msg

{- | Run a decoder over the @Constr@ args of a raw node: exactly one
@unConstrData@ and one monotone walk per region.
-}
{-# INLINE walking #-}
walking :: BuiltinData -> Decoder a -> Validator a
walking d (Decoder m) = Validator \k ->
  m (BI.snd (wrapUnsafeDataAsConstr d)) \a _ -> k a
