{-# LANGUAGE NoImplicitPrelude #-}
--
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}

{- |
A zero-cost, composable early-termination DSL for Plinth: a @Cont@-style monad
that sequences decode-or-abort steps and boolean guards into a FLAT chain.
See Note [Zero-cost Validator monad].
-}
module Plinth.Validator (
  Validator (Validator),
  bindValidator,
  thenValidator,
  runValidator,
  validate,

  -- * @do@-notation support (for @RebindableSyntax@ consumers)
  (>>=),
  (>>),
  fromInteger,
) where

import PlutusTx.Builtins.Internal (BuiltinUnit, unitval)
import PlutusTx.Prelude (Bool, BuiltinString, Integer, traceError)

{- Note [Zero-cost Validator monad]
'Validator' is a @Cont@-style monad sequencing decode-or-abort steps and boolean
guards into a FLAT chain while preserving short-circuit and on-demand (@asData@)
decode. It compiles to zero overhead, without any plugin change, for two reasons:

  * the combinators are @INLINE@, so GHC inlines them before the Plinth plugin
    runs and the PIR call-site threshold never gets to decline them;
  * sequencing right-associates (via the 'infixr' fixities / @do@-notation), which
    the optimiser folds tighter than the left-associated form.

Short-circuit + on-demand decode hold because the continuation lives INSIDE the
@\\k -> …@ lambda: under Plinth's strict (call-by-value) application that keeps
each later guard/decode delayed, so an early 'validate' failure aborts before any
deeper step decodes its layer.
-}

{- | A validator parameterised over its continuation.
See Note [Zero-cost Validator monad].
-}
newtype Validator a = Validator ((a -> BuiltinUnit) -> BuiltinUnit)

infixr 1 `bindValidator`

infixr 1 `thenValidator`

-- | Monadic bind: thread the decoded value into the next validator.
{-# INLINE bindValidator #-}
bindValidator :: Validator a -> (a -> Validator b) -> Validator b
bindValidator (Validator m) f = Validator \k ->
  m \a -> case f a of Validator n -> n k

-- | Sequence two validators, discarding the first's result.
{-# INLINE thenValidator #-}
thenValidator :: Validator a -> Validator b -> Validator b
thenValidator (Validator m) (Validator n) = Validator \k -> m \_ -> n k

-- | Run a validator chain: succeed with @unit@ if every step continues.
{-# INLINE runValidator #-}
runValidator :: Validator () -> BuiltinUnit
runValidator (Validator f) = f \_ -> unitval

-- | A boolean guard: continue, or abort with a trace message.
{-# INLINE validate #-}
validate :: BuiltinString -> Bool -> Validator ()
validate msg cond = Validator (\k -> if cond then k () else traceError msg)

--------------------------------------------------------------------------------
-- do-notation support ---------------------------------------------------------
--
-- A consumer writing a validator on the 'Validator' monad with @do@-notation enables
-- @RebindableSyntax@ and imports these (hiding the 'PlutusTx.Prelude'
-- counterparts), so the validator module carries no DSL plumbing of its own.

-- | @RebindableSyntax@ bind for @do@.
(>>=) :: Validator a -> (a -> Validator b) -> Validator b
(>>=) = bindValidator
{-# INLINE (>>=) #-}

-- | @RebindableSyntax@ sequencing for @do@.
(>>) :: Validator a -> Validator b -> Validator b
(>>) = thenValidator
{-# INLINE (>>) #-}

{- | @RebindableSyntax@ routes every integer literal through 'fromInteger', and
the one 'PlutusTx.Prelude' exports targets 'Rational'. On-chain validator
literals are 'Integer', so bind it to the identity.
-}
fromInteger :: Integer -> Integer
fromInteger n = n
{-# INLINE fromInteger #-}
