{-# LANGUAGE AllowAmbiguousTypes #-}
-- CPP selects the skip-emission strategy: the PREVIEW build compiles a
-- 3-or-more-field cursor gap to ONE @dropList@ call (a batch-6 builtin,
-- not yet on mainnet); the production build unrolls every gap into
-- @tailList@ steps. See Note [Emitting dropList for wide gaps].
{-# LANGUAGE CPP #-}
-- DataKinds is needed ONLY for the 'TypeError' catch-all instances; the
-- promoted 'ErrorMessage' kind never reaches the plugin, because those
-- instances are selected exclusively in programs that FAIL to type-check.
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
-- TypeOperators is likewise only for ':<>:'/':$$:' in the error messages.
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}
-- 'FieldAt' has no methods, so GHC deems its constraints redundant; they are
-- not — they drive the functional-dependency improvement of @ix@/@ty@.
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
--
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}

{- |
By-name, type-directed field projection over "Plinth.Decoder".
The validator author names fields; Constr indices, walk direction and
@skip@ counts live in the type system. See Note [Indexed projection].

With @QualifiedDo@ (import this module qualified, e.g. as @N@), a region is an
ordinary-looking @do@ block — @N.do@ desugars to 'bindF'/'thenF', so the
indexed types (and the compile-time walk checking they carry) pass through
unchanged, and it coexists with a @RebindableSyntax@ @do@ already claimed by
another monad in the same module:

> import Plinth.Decoder.Named (field, fields, yield, walkF)
> import Plinth.Decoder.Named qualified as N
>
> splitTxInfo :: TxInfo -> Validator (Encoded POSIXTimeRange, Encoded (List PubKeyHash))
> splitTxInfo txInfo =
>   walkF txInfo N.do
>     validRange <- field @TxInfoValidRange
>     signatories <- field @TxInfoSignatories
>     yield (validRange, signatories)

A region that only projects fields (no mid-walk transformation or guard) is
one 'fields' step, spelled as the tuple of tags:

> splitTxInfo txInfo =
>   walkF txInfo (fields @(TxInfoValidRange, TxInfoSignatories))
-}
module Plinth.Decoder.Named (
  -- * Layout: the only place field indices (and types) exist
  FieldAt,
  N0,
  N1,
  N2,
  N3,
  N4,
  N5,
  N6,
  N7,
  N8,
  N9,
  N10,
  N11,
  N12,
  N13,
  N14,
  N15,

  -- * Indexed decoder
  IxDecoder (IxDecoder),
  bindF,
  thenF,
  yield,
  field,
  Fields (fields),
  atField,
  walk,
  walkRaw,
  walkF,

  -- * @QualifiedDo@ support (import qualified, write @N.do@)
  (>>=),
  (>>),

  -- * Type-level machinery (exported for error messages)
  Z,
  S,
  Minus,
  SkipsTo,
  Drops,
) where

import Data.Type.Equality (type (~))
import GHC.TypeLits (ErrorMessage (ShowType, Text, (:$$:), (:<>:)), TypeError)
import Plinth.Decoder (
  Decoder,
  bindDecoder,
  fieldRaw,
  pureDecoder,
  skip,
#ifdef PREVIEW
  skips,
#endif
  thenDecoder,
  walking,
 )
import Plinth.Encoded (Encoded (Encoded))
import Plinth.Validator (Validator)
import PlutusTx.AsData.Internal (wrapTail, wrapUnsafeDataAsConstr)
import PlutusTx.Builtins.Internal (BuiltinData)
import PlutusTx.Builtins.Internal qualified as BI
import PlutusTx.IsData.Class (ToData, toBuiltinData)

{- Note [Indexed projection]
'IxDecoder' is 'Decoder' with two phantom type parameters — the cursor's
Constr position before and after the step — so the RUNTIME REPRESENTATION is
exactly 'Decoder' (a newtype; the phantoms erase) and the zero-cost property
is inherited rather than re-established. What the indices buy:

  * 'bindF' composes @i -> j@ with @j -> k@: a step that would walk BACKWARDS
    (demanding a field at an index below the cursor) has no 'Minus' solution
    — the gap does not exist — and does not compile. The fix is
    mechanical: reorder the steps (the compiler tracks the valid path; the
    author never sees the indices themselves).
  * a field tag is checked against the WALKED TYPE @t@ (propagated from the
    'walk' argument): demanding @TxInfoSignatories@ inside a walk over a
    user datum is a domain-worded type error (see the 'FieldAt' catch-all);
    a misspelled tag is a native GHC scope error.

'FieldAt' is the type-level layout (a fundep class, see its haddock). The library ships
instances for the stable V3 ledger types ("Plinth.Decoder.Named.ScriptContext"); a
user type gets one instance per field next to its @asData@ declaration.
There is no specialisation of the decoder itself to any schema: knowing the
schema IS the instance set, the machinery is generic and free either way.

Positions are unary naturals ('Z'/'S') at kind 'Type' — see
Note [Why Z/S instead of GHC type-level naturals].

The @skip@ chain for the gap between the cursor and the demanded index is
unrolled at compile time by 'SkipsTo' — induction over the 'Minus' gap.
'SkipsTo' is a single-method class: its dictionary is (a coercion of) the
method itself, so GHC inlines the instance chain away completely and the
residual term is the same @skip \`thenDecoder\` … fieldRaw@ chain one would
write by hand. No dictionaries survive to PIR (verified by measuring:
cost-identical to the hand-written walk on every scenario).
-}

{- Note [Why Z/S instead of GHC type-level naturals]
GHC's native type-level numbers ('GHC.TypeLits.Nat') look like the obvious
representation for the cursor positions. Two reasons they cannot work here:

  * The Plinth plugin compiles typed Core into PIR, whose kind system has only
    'Type' and arrows. Any type argument of a PROMOTED kind ('Nat', 'Symbol',
    promoted data constructors) that survives in Core — as the 'IxDecoder'
    phantoms do — is rejected ("Unsupported feature: Kind: …"). Ordinary empty
    datatypes at kind 'Type' compile like any other type. Field names follow
    the same rule: they are empty kind-'Type' TAG types (@TxInfoValidRange@),
    not 'Symbol's — which also drops the quotes from type applications.
  * Compile-time induction ('SkipsTo') needs a structurally recursive number
    to recurse on; opaque 'Nat' literals would have to be converted to unary
    form anyway. 'Nat' would buy literal syntax, not machinery.

The same wall rules out @OverloadedLabels@ syntax (@field #txInfoValidRange@
or a bare @#txInfoValidRange@ step): a label must materialise as a VALUE via
'GHC.OverloadedLabels.fromLabel', and whichever carrier one picks — a
@data FieldName (name :: Symbol)@ token, or an @IsLabel@ instance on
'IxDecoder' itself — something 'Symbol'-indexed survives at the value level
for the plugin to reject (measured: both variants fail with "Unsupported
feature: Kind: GHC.Types.Symbol"). Type applications are the plugin-safe
spelling (erased by GHC inlining before the plugin walks the unfolding), and
kind-'Type' field tags make them quote-free: @'field' \@TxInfoValidRange@.
-}

{- | Unary zero, at kind 'Type'
(see Note [Why Z/S instead of GHC type-level naturals]). Uninhabited.
-}
data Z

-- | Unary successor, at kind 'Type'. Uninhabited.
data S n

type N0 = Z

type N1 = S N0

type N2 = S N1

type N3 = S N2

type N4 = S N3

type N5 = S N4

type N6 = S N5

type N7 = S N6

type N8 = S N7

type N9 = S N8

type N10 = S N9

type N11 = S N10

type N12 = S N11

type N13 = S N12

type N14 = S N13

type N15 = S N14

{- | The type-level layout: the tagged field of @t@ sits at Constr index @ix@
(a unary 'Z'/'S' natural) and has type @ty@ — one instance per field, keyed by
an empty field-tag type (e.g. @TxInfoValidRange@ — kind 'Type', so quote-free
in type applications and plugin-safe). See "Plinth.Decoder.Named.ScriptContext"
for the V3 ledger types and their tags.

A CLASS with functional dependencies, deliberately not a pair of type
families: fundep improvement substitutes @ix@/@ty@ CONCRETELY into Core
types, whereas a type-family application (even a fully concrete one) can
survive un-normalised in a binder type, and the Plinth plugin does not
reduce families — a surviving application is a fatal
"Irreducible type family application".
-}
class FieldAt tag t ix ty | tag t -> ix ty

{- Catch-all with a domain-language error. OVERLAPPABLE: any concrete layout
instance is more specific and wins; this one is selected only in programs
that are already rejected, so the promoted 'ErrorMessage' never survives to
the plugin. Its fundep RHS are bare variables (the equalities below are dummy
determinations for the coverage condition, never observed), so it adds no
improvement and cannot conflict with the real instances.

The message hedges between two causes: for an ORDERING error the solver may
blame this 'FieldAt' wanted rather than the stuck 'Minus' one, and its blame
assignment is not ours to choose — so the text must be truthful under both.
-}
instance
  {-# OVERLAPPABLE #-}
  ( ix ~ Z
  , ty ~ ()
  , TypeError
      ( 'Text "Cannot read field ‘"
          ':<>: 'ShowType tag
          ':<>: 'Text "’ while walking a ‘"
          ':<>: 'ShowType t
          ':<>: 'Text "’. Either:"
          ':$$: 'Text "• it is not a field of ‘"
            ':<>: 'ShowType t
            ':<>: 'Text "’ — no ‘FieldAt "
            ':<>: 'ShowType tag
            ':<>: 'Text " "
            ':<>: 'ShowType t
            ':<>: 'Text " …’ layout instance exists"
          ':$$: 'Text "  (V3 layout: Plinth.Decoder.Named.ScriptContext; user types declare"
          ':$$: 'Text "  instances next to their asData definitions), or"
          ':$$: 'Text "• the field lies BEHIND the cursor — a region reads fields in"
          ':$$: 'Text "  ascending Constr-index order; reorder the steps."
      )
  ) =>
  FieldAt tag t ix ty

{- | The cursor gap @gap = a - b@; no instance (a compile error at the
offending step) when @b > a@, i.e. when the demanded field is already behind
the cursor.

A fundep CLASS and not a type family, for the same plugin reason as
'FieldAt' — a family application leaks into Core even from constraint
position once it passes through an instance-method dictionary, and the
plugin cannot reduce it; fundep improvement substitutes @gap@ concretely.
-}
class Minus a b gap | a b -> gap

instance Minus a Z a

instance Minus a b gap => Minus (S a) (S b) gap

{- Catch-all with a domain-language error for a backwards step (the demanded
index is below the cursor, so the subtraction has no solution). Same
plugin-safety reasoning as the 'FieldAt' catch-all above.
-}
instance
  {-# OVERLAPPABLE #-}
  ( gap ~ Z -- dummy determination for the fundep coverage condition
  , TypeError
      ( 'Text "This field is BEHIND the cursor: a walk region reads the fields"
          ':$$: 'Text "of a node in ascending Constr-index order and never goes back."
          ':$$: 'Text "Reorder the steps to demand the fields in layout order"
          ':$$: 'Text "(the indices live in the ‘FieldAt’ instances of the walked type)."
      )
  ) =>
  Minus a b gap

{- Note [Emitting dropList for wide gaps]
A cursor gap compiles to @tailList@ steps or to one @dropList n@ call.
Measured head to head on one field projection with the gap emitted both
ways, replicating the CAPE measurement pipeline (CEK cost model
variant E, @serialiseCompiledCode@ size, mainnet fee prices): a chained
@tailList@ step costs 113 663 CPU (81 663 builtin + apply + force) and
2 bytes of term, while @dropList@ costs 116 711 + 1 957·n CPU in ONE
call whose term size does not grow with the gap. Total fee of the
projection through a gap of n:

  gap        1    2    3    4    5    6    7    8
  chain fee  594  645  697  748  800  852  903  955
  drop  fee  654  654  654  654  654  654  654  655

The single call wins on cpu from a 2-field gap; on the primary
objective (total_fee_lovelace) the crossover is a 3-field gap — at 2 the
chain still wins by 9 lovelace because the drop spelling is one byte
larger. From 3 up the call wins on every axis at once, so the threshold
needs no per-axis compromise.

@dropList@ is a batch-6 builtin — PlutusV3 accepts it only from the
van Rossem protocol version, which is not on mainnet — so the emission is
gated to the PREVIEW build (same track as @datatypes=BuiltinCasing@).
The production build keeps the pure @tailList@ induction and its
artifacts stay byte-identical.

The gap count crosses from type to term as a HAND-WRITTEN literal in one
closed instance per gap (3..15, the 'FieldAt' index range). Deriving the
literal from the type (an inductive @1 + natVal \@p@) does not survive the
trip: the plugin compiles the UNSIMPLIFIED unfoldings of INLINE bindings,
so the addition chain reaches it unfolded and is rejected as a reference
to @GHC.Num.Integer.integerAdd@ — constant folding is a simplifier pass
the plugin never benefits from.
-}

-- | Compile-time unrolling of the @skip@ chain covering a cursor gap.
class SkipsTo p where
  skipsThen :: Decoder a -> Decoder a

#ifdef PREVIEW

instance SkipsTo Z where
  skipsThen d = d
  {-# INLINE skipsThen #-}

instance SkipsTo (S Z) where
  skipsThen d = skip `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S Z)) where
  skipsThen d = skip `thenDecoder` skip `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S Z))) where
  skipsThen d = skips 3 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S Z)))) where
  skipsThen d = skips 4 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S (S Z))))) where
  skipsThen d = skips 5 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S (S (S Z)))))) where
  skipsThen d = skips 6 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S (S (S (S Z))))))) where
  skipsThen d = skips 7 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S (S (S (S (S Z)))))))) where
  skipsThen d = skips 8 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S (S (S (S (S (S Z))))))))) where
  skipsThen d = skips 9 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S (S (S (S (S (S (S Z)))))))))) where
  skipsThen d = skips 10 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S (S (S (S (S (S (S (S Z))))))))))) where
  skipsThen d = skips 11 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S (S (S (S (S (S (S (S (S Z)))))))))))) where
  skipsThen d = skips 12 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S (S (S (S (S (S (S (S (S (S Z))))))))))))) where
  skipsThen d = skips 13 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S (S (S (S (S (S (S (S (S (S (S Z)))))))))))))) where
  skipsThen d = skips 14 `thenDecoder` d
  {-# INLINE skipsThen #-}

instance SkipsTo (S (S (S (S (S (S (S (S (S (S (S (S (S (S (S Z))))))))))))))) where
  skipsThen d = skips 15 `thenDecoder` d
  {-# INLINE skipsThen #-}

#else

instance SkipsTo Z where
  skipsThen d = d
  {-# INLINE skipsThen #-}

instance SkipsTo p => SkipsTo (S p) where
  skipsThen d = skip `thenDecoder` skipsThen @p d
  {-# INLINE skipsThen #-}

#endif

{- | A 'Decoder' whose cursor position is tracked in the type: @i@ is the
Constr index under the cursor before the step, @j@ after. Phantom-only — the
runtime representation is exactly 'Decoder'.
-}
newtype IxDecoder t i j a = IxDecoder (Decoder a)

infixr 1 `bindF`

infixr 1 `thenF`

-- | Indexed bind: the cursor position composes @i -> j -> k@.
bindF :: IxDecoder t i j a -> (a -> IxDecoder t j k b) -> IxDecoder t i k b
bindF (IxDecoder m) f =
  IxDecoder (m `bindDecoder` \a -> case f a of IxDecoder n -> n)
{-# INLINE bindF #-}

-- | Indexed sequencing, discarding the first result.
thenF :: IxDecoder t i j a -> IxDecoder t j k b -> IxDecoder t i k b
thenF (IxDecoder m) (IxDecoder n) = IxDecoder (m `thenDecoder` n)
{-# INLINE thenF #-}

-- | Yield a value; the cursor does not move.
yield :: a -> IxDecoder t i i a
yield a = IxDecoder (pureDecoder a)
{-# INLINE yield #-}

{- | The named field of the walked type, raw. The cursor rests ON the field
just read; the @skip@ chain covering the gap from the current position —
including the step off a previously read field — is derived and unrolled at
compile time. A field strictly behind the cursor does not compile; re-reading
the field under the cursor is legal (a zero gap). Because the cursor never
advances past a read, a region's last read leaves no dead trailing @tailList@
— there is no separate \"last field\" combinator to choose.
-}
field ::
  forall tag t i ix ty gap.
  (FieldAt tag t ix ty, Minus ix i gap, SkipsTo gap) =>
  IxDecoder t i ix (Encoded ty)
field =
  IxDecoder
    ( skipsThen @gap fieldRaw
        `bindDecoder` \d -> pureDecoder (Encoded d)
    )
{-# INLINE field #-}

{- | A whole walk region from a tuple of field TAGS: the spec @(A, B, …)@
mirrors the result @('Encoded' tyA, 'Encoded' tyB, …)@ — several fields of one
node extracted in a single shared walk. @'fields' \@(A, B)@ is definitionally
the @N.do@ region @{ a <- 'field' \@A; b <- 'field' \@B; 'yield' (a, b) }@,
including the compile-time ordering check: a spec not in ascending Constr
order has no 'SkipsTo' solution and does not compile.

The spec is an ordinary tuple TYPE at kind 'Type' — not a promoted list
@'[A, B]@, whose kind the Plinth plugin rejects (see
Note [Why Z/S instead of GHC type-level naturals]). Distinct arities are
distinct type constructors, so the instances neither overlap nor conflict
under the fundep; a bare single tag cannot join this class for the same
reason (its head would unify with every tuple head) — for one field use
'field' directly.
-}
class Fields spec t i j ty | spec t i -> j ty where
  fields :: IxDecoder t i j ty

instance
  ( FieldAt a t ia x
  , Minus ia i ga
  , SkipsTo ga
  , FieldAt b t ib y
  , Minus ib ia gb
  , SkipsTo gb
  ) =>
  Fields (a, b) t i ib (Encoded x, Encoded y)
  where
  fields =
    field @a `bindF` \x ->
      field @b `bindF` \y ->
        yield (x, y)
  {-# INLINE fields #-}

instance
  ( FieldAt a t ia x
  , Minus ia i ga
  , SkipsTo ga
  , FieldAt b t ib y
  , Minus ib ia gb
  , SkipsTo gb
  , FieldAt c t ic z
  , Minus ic ib gc
  , SkipsTo gc
  ) =>
  Fields (a, b, c) t i ic (Encoded x, Encoded y, Encoded z)
  where
  fields =
    field @a `bindF` \x ->
      field @b `bindF` \y ->
        field @c `bindF` \z ->
          yield (x, y, z)
  {-# INLINE fields #-}

instance
  ( FieldAt a t ia x
  , Minus ia i ga
  , SkipsTo ga
  , FieldAt b t ib y
  , Minus ib ia gb
  , SkipsTo gb
  , FieldAt c t ic z
  , Minus ic ib gc
  , SkipsTo gc
  , FieldAt d t id_ w
  , Minus id_ ic gd
  , SkipsTo gd
  ) =>
  Fields (a, b, c, d) t i id_ (Encoded x, Encoded y, Encoded z, Encoded w)
  where
  fields =
    field @a `bindF` \x ->
      field @b `bindF` \y ->
        field @c `bindF` \z ->
          field @d `bindF` \w ->
            yield (x, y, z, w)
  {-# INLINE fields #-}

-- | Compile-time unrolling of a PURE walk to a field (for 'atField').
-- The gap-emission strategy mirrors 'SkipsTo' — see
-- Note [Emitting dropList for wide gaps].
class Drops p where
  drops :: BI.BuiltinList BuiltinData -> BI.BuiltinList BuiltinData

#ifdef PREVIEW

instance Drops Z where
  drops s = s
  {-# INLINE drops #-}

instance Drops (S Z) where
  drops s = wrapTail s
  {-# INLINE drops #-}

instance Drops (S (S Z)) where
  drops s = wrapTail (wrapTail s)
  {-# INLINE drops #-}

instance Drops (S (S (S Z))) where
  drops s = BI.drop 3 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S Z)))) where
  drops s = BI.drop 4 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S (S Z))))) where
  drops s = BI.drop 5 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S (S (S Z)))))) where
  drops s = BI.drop 6 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S (S (S (S Z))))))) where
  drops s = BI.drop 7 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S (S (S (S (S Z)))))))) where
  drops s = BI.drop 8 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S (S (S (S (S (S Z))))))))) where
  drops s = BI.drop 9 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S (S (S (S (S (S (S Z)))))))))) where
  drops s = BI.drop 10 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S (S (S (S (S (S (S (S Z))))))))))) where
  drops s = BI.drop 11 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S (S (S (S (S (S (S (S (S Z)))))))))))) where
  drops s = BI.drop 12 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S (S (S (S (S (S (S (S (S (S Z))))))))))))) where
  drops s = BI.drop 13 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S (S (S (S (S (S (S (S (S (S (S Z)))))))))))))) where
  drops s = BI.drop 14 s
  {-# INLINE drops #-}

instance Drops (S (S (S (S (S (S (S (S (S (S (S (S (S (S (S Z))))))))))))))) where
  drops s = BI.drop 15 s
  {-# INLINE drops #-}

#else

instance Drops Z where
  drops s = s
  {-# INLINE drops #-}

instance Drops p => Drops (S p) where
  drops s = drops @p (wrapTail s)
  {-# INLINE drops #-}

#endif

{- | Pure single-field projection: one walk of the node to the tagged field,
usable inside guards (no monad, no region). For extracting SEVERAL fields of
one node prefer a 'walk'/'walkF' region, which shares the walk.
-}
atField ::
  forall tag t ix ty.
  (FieldAt tag t ix ty, Drops ix) =>
  Encoded t ->
  Encoded ty
atField (Encoded d) =
  Encoded (BI.head (drops @ix (BI.snd (wrapUnsafeDataAsConstr d))))
{-# INLINE atField #-}

{- | Run a region over the @Constr@ args of an encoded node — ONE walk of its
spine, the cost unit of this design: count the 'walk's in a validator and you
have counted the @unConstrData@ + spine passes. No decode happens — the
fields come out still 'Encoded' (the phantom of the argument selects the
'FieldAt' layout the region walks by, and ties it to every 'field'\/'fields'
inside); 'Plinth.Encoded.decode' is where a paid structural decode happens.
-}
walk :: forall t j a. Encoded t -> IxDecoder t Z j a -> Validator a
walk (Encoded d) (IxDecoder m) = walking d m
{-# INLINE walk #-}

{- | 'walk' from a raw script argument, CLAIMING its type — the trust
boundary where unverified 'BuiltinData' enters the typed world:
@'walkRaw' \@ScriptContext ctxData@ ≡
@'walk' ('Encoded' ctxData :: 'Encoded' ScriptContext)@. Typically the
first line of a validator; everything downstream is 'Encoded'.
-}
walkRaw :: forall t j a. BuiltinData -> IxDecoder t Z j a -> Validator a
walkRaw d (IxDecoder m) = walking d m
{-# INLINE walkRaw #-}

{- | 'walk' from a not-yet-forgotten value of @t@ (a free coerce for
@asData@-backed types).
-}
walkF :: ToData t => t -> IxDecoder t Z j a -> Validator a
walkF t (IxDecoder m) = walking (toBuiltinData t) m
{-# INLINE walkF #-}

--------------------------------------------------------------------------------
-- QualifiedDo support ----------------------------------------------------------
--
-- A consumer imports this module qualified (say, as @N@) and writes @N.do@;
-- GHC desugars the block with these operators, leaving the module's
-- unqualified @do@ free for other monads.

-- | @QualifiedDo@ bind for @N.do@; 'bindF'.
(>>=) :: IxDecoder t i j a -> (a -> IxDecoder t j k b) -> IxDecoder t i k b
(>>=) = bindF
{-# INLINE (>>=) #-}

infixr 1 >>=

-- | @QualifiedDo@ sequencing for @N.do@; 'thenF'.
(>>) :: IxDecoder t i j a -> IxDecoder t j k b -> IxDecoder t i k b
(>>) = thenF
{-# INLINE (>>) #-}

infixr 1 >>
