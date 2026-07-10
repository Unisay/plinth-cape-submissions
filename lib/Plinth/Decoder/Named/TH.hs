{-# LANGUAGE TemplateHaskell #-}

{- |
Derive the "Plinth.Decoder.Named" field layout — the uninhabited tag types and
their 'FieldAt' instances — for a user datatype straight from the same
@[d| … |]@ quote that 'asData' consumes, so the layout is never written, or
audited, by hand.

Use 'asDataLaidOut' exactly where 'asData' was used:

> asDataLaidOut
>   [d|
>     data HTLCDatum = HTLCDatum
>       { payer :: Address
>       , recipient :: Address
>       , secretHash :: BuiltinByteString
>       , timeout :: POSIXTime
>       }
>       deriving newtype (FromData, ToData, UnsafeFromData)
>   |]

It emits everything 'asData' does (the @BuiltinData@ newtype and its pattern
synonyms) AND, per record field, a @data \<Tag\>@ plus
@instance FieldAt \<Tag\> \<T\> \<ix\> \<ty\>@. Validator code then names the
field with @'Plinth.Decoder.Named.field' \@Payer@ (read qualified through the
fixture alias). See
Note [Layout is byte-identical and drift-proof] and
Note [Sum-type layouts commit to a constructor].
-}
module Plinth.Decoder.Named.TH (
  asDataLaidOut,
  deriveLayout,
  deriveLayoutFor,
) where

import Data.Char (toUpper)
import Language.Haskell.TH
import Plinth.Decoder.Named (FieldAt, S, Z)
import PlutusTx.AsData (asData)
import Text.Show (show)
import Prelude hiding (Type, show)

{- Note [Layout is byte-identical and drift-proof]
The generated declarations are the SAME ordinary decls one writes by hand: an
uninhabited @data \<Tag\>@ (kind 'Data.Kind.Type', erased) and a method-less
@instance FieldAt …@ (no dictionary survives — see Note [Indexed projection] in
"Plinth.Decoder.Named"). The compiled @.uplc@ depends on the layout only
through the field INDICES, via the @SkipsTo@/@Drops@ skip-chain unrolling;
'deriveLayout' takes each index from the field's source position, which is
exactly the position 'asData' encodes it at.

Two consequences. A hand-written layout and a derived one that agree on the
schema compile to byte-identical UPLC — switching a scenario to 'asDataLaidOut'
is a no-op on every cost axis, confirmable by a zero @.uplc@ checksum diff and
needing no re-measurement. And because both the encoding and the layout now
read their indices from ONE quote, they cannot drift apart; a non-zero diff
after the switch does not signal a regression but that the previous
hand-written index was wrong (the latent bug this deriver removes — most
dangerous among same-typed fields, where a swap still type-checks).
-}

{- Note [Sum-type layouts commit to a constructor]
For a multi-constructor type the fields of EACH constructor are laid out from
index 0 of THAT constructor's @Constr@ node — the index resets per constructor,
it is not the constructor tag. A tag such as @Claim0@ therefore
only makes sense once the runtime constructor is known to be @Claim@: walking
it over a @Refund@ value heads an empty args list and aborts. This mirrors the
hand-written ledger tags (@SpendingScriptOutRef@, @FiniteValue@, @JustValue@ in
"Plinth.Decoder.Named.ScriptContext"), which likewise commit to a constructor
without re-checking the tag. Guard on 'Plinth.Encoded.tagOf' first when the
constructor is not already an invariant of the code path.
-}

-- | 'asData', plus the derived 'FieldAt' layout from the same declarations.
asDataLaidOut :: Q [Dec] -> Q [Dec]
asDataLaidOut q = do
  decs <- q
  core <- asData (pure decs)
  layout <- concat <$> traverse deriveLayout decs
  pure (core <> layout)

{- | Layout for a type declared elsewhere (e.g. via @makeIsDataIndexed@ on an
ordinary datatype, whose type — unlike an @asData@ newtype — survives
compilation): 'reify' the datatype and emit the tags + 'FieldAt' instances from
its constructors. Splice it in the module that walks the type; no export-list
change is needed, since the tags land in that module. Fails at the splice site
if @name@ does not resolve to a @data@ or @newtype@ declaration.
-}
deriveLayoutFor :: Name -> Q [Dec]
deriveLayoutFor name =
  reify name >>= \case
    TyConI dec@DataD {} -> deriveLayout dec
    TyConI dec@NewtypeD {} -> deriveLayout dec
    info ->
      fail $
        "deriveLayoutFor: `"
          <> show name
          <> "` does not resolve to a `data`/`newtype` declaration, so no FieldAt "
          <> "layout can be derived. Pass a record or sum type (e.g. one made "
          <> "serialisable with makeIsDataIndexed), not a type synonym, class, or "
          <> "data constructor. reify returned: "
          <> show info

{- | The layout declarations for one datatype from a quote: records and sums
are handled (one tag type + 'FieldAt' instance per field), everything else is
skipped. Exposed so a caller can lay out a type whose 'asData' runs elsewhere.
-}
deriveLayout :: Dec -> Q [Dec]
deriveLayout = \case
  DataD _ ty _ _ cons _ -> layoutForCons ty cons
  NewtypeD _ ty _ _ con _ -> layoutForCons ty [con]
  _ -> pure []

layoutForCons :: Name -> [Con] -> Q [Dec]
layoutForCons ty cons = concat <$> traverse perCon cons
  where
    single = length cons == 1
    perCon con =
      concat
        <$> traverse
          ( \(ix, (mSel, fieldTy)) ->
              fieldDecls ty (tagName single (conName con) mSel ix) ix fieldTy
          )
          (zip [0 ..] (conFields con))

-- | The uninhabited tag type and its 'FieldAt' instance for one field.
fieldDecls :: Name -> Name -> Int -> Type -> Q [Dec]
fieldDecls ty tag ix fieldTy =
  pure
    [ DataD [] tag [] Nothing [] []
    , InstanceD
        Nothing
        []
        (ConT ''FieldAt `AppT` ConT tag `AppT` ConT ty `AppT` peano ix `AppT` fieldTy)
        []
    ]

{- | The tag type name: @\<Field\>@ for a single-constructor type,
@\<Constructor\>\<Field\>@ for a sum; a positional (non-record) field
contributes its index in place of a selector name. There is no type prefix —
tags are meant to be read qualified through the fixture's module alias, e.g.
@'Plinth.Decoder.Named.field' \@Vesting.PeriodStart@.
-}
tagName :: Bool -> Name -> Maybe Name -> Int -> Name
tagName single ctor mSel ix = mkName (prefix <> fieldPart)
  where
    prefix
      | single = ""
      | otherwise = nameBase ctor
    fieldPart = maybe (show ix) (upperFirst . nameBase) mSel

conName :: Con -> Name
conName = \case
  NormalC n _ -> n
  RecC n _ -> n
  InfixC _ n _ -> n
  _ -> mkName "Con" -- unused: unsupported constructors contribute no fields

conFields :: Con -> [(Maybe Name, Type)]
conFields = \case
  NormalC _ bts -> [(Nothing, t) | (_, t) <- bts]
  RecC _ vbts -> [(Just n, t) | (n, _, t) <- vbts]
  InfixC l _ r -> [(Nothing, snd l), (Nothing, snd r)]
  _ -> []

peano :: Int -> Type
peano n
  | n <= 0 = ConT ''Z
  | otherwise = ConT ''S `AppT` peano (n - 1)

upperFirst :: String -> String
upperFirst = \case
  c : cs -> toUpper c : cs
  [] -> []
