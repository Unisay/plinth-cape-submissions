# Bytestring-key value lookups

Read an asset's quantity from an on-chain `Value` by key, comparing the map keys as raw bytestrings (`equalsByteString` on the unwrapped `CurrencySymbol` / `TokenName`) instead of `equalsData` on the whole key `Data`. This is the keyed counterpart to [positional-value-reads.md](positional-value-reads.md): reach for it when the asset's slot is not fixed by an invariant, so a positional read does not apply.

## The technique

A `Value` is a nested map, `Map CurrencySymbol (Map TokenName Integer)`, and both key layers encode as `Data` `B` (bytestring) nodes. The natural lookup compares each key with `equalsData` on the whole `Data`. Comparing the unwrapped bytes instead is cheaper: unwrap the search key once with `unsafeDataAsB`, unwrap each stored key the same way, and compare with `equalsByteString`.

The repo exposes this as `lookupBytesE` in `Plinth.Encoded`, the bytestring-keyed sibling of `lookupE`. It keeps the continuation-passing shape, so no `Maybe` materialises, and `assetAmount` nests two of them, one per map layer:

```haskell
assetAmount (Encoded v) (Encoded cs) (Encoded tn) =
  lookupBytesE
    (BI.unsafeDataAsB cs)
    0
    (lookupBytesE (BI.unsafeDataAsB tn) 0 (decode @Integer))
    (Encoded v)
```

## Why it is cheaper

`equalsData` on two `B` nodes must dispatch on the `Data` constructor before it can compare bytes; `unsafeDataAsB` then `equalsByteString` skips that dispatch. It is one extra builtin per element (the unwrap), yet still wins, so the `Data`-equality overhead dominates that unwrap.

This was not assumed. Three shapes were measured at a fixed inliner budget: the `equalsData` `lookupE`, an inline hand-unrolled `equalsByteString` recursion, and the shared `lookupBytesE` combinator. The combinator keeps the compact size of `lookupE` and almost all of the unrolled form's cpu win, which pins the gain on the comparison builtin rather than the loop structure. The inline unroll cost about 130 extra bytes for no net fee change and was dropped.

Note the upstream premise does not hold: `PlutusLedgerApi.V1.Data.Value.valueOf` and the Data-backed `Map.lookup` both compare keys with `equalsData`, not `equalsByteString`. This is a local win, not a port.

## When it applies

- A keyed read of a `Value` (or any bytestring-keyed map) where the asset's position is not fixed, so [positional reads](positional-value-reads.md) do not apply. LinearVesting reads its vesting token by `(CurrencySymbol, TokenName)` from the datum.
- Maps whose keys are bytestrings: `CurrencySymbol`, `TokenName`, `PubKeyHash`, `DatumHash`.

## When it does not apply

- Maps with constructor (non-bytestring) keys, such as `Map Credential Lovelace`. `unsafeDataAsB` on a `Constr` key errors, so keep the `equalsData`-based `lookupE` for those.
- The fixed-slot lovelace case, where the cheaper move is a positional read (`adaOf`) with no key comparison at all.

## Measured effect

`linear_vesting` (Plinth 1.65), all scenario cases behaving as before, per-build inliner budget re-swept:

| build | keyed via `equalsData` | keyed via `equalsByteString` |
| --- | ---: | ---: |
| prod (mainnet) | 59,048 | 58,343 |
| preview | 49,805 | 48,971 |

That is roughly 1.2% to 1.7% off total fee and 7.5% to 10% off cpu from the comparison change alone. `mem.sum` rises about 1% (`equalsByteString` reads both operands where `equalsData` can stop early on a length mismatch), which the cpu drop more than covers.

## Used by

- `LinearVesting`: `assetAmount` nests two `lookupBytesE`.
