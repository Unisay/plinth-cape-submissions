# Positional value reads

Read a known asset's quantity from an on-chain `Value` by position, instead of the keyed `valueOf` / `assetAmount` lookup, when the ledger's canonical ordering fixes where that asset sits.

## The technique

A `Value` is a nested map, `Map CurrencySymbol (Map TokenName Integer)`. The usual accessor (`valueOf v cs tn`, and upstream `lovelaceValueOf`) walks the outer map comparing each currency-symbol key, then the inner map comparing each token-name key. For ADA that is two key comparisons plus the key unwrapping on every call.

A ledger-provided `TxOut` `Value` is canonical: policy ids are sorted, the empty policy id (ADA) sorts first, and every `TxOut` carries ADA (min-ada). So the lovelace amount is always the first entry of the first entry. Reading it by position, `head` then `snd` twice, is correct and skips both key comparisons:

```haskell
adaOf (Encoded v) =
  let adaTokens = BI.snd (BI.head (BI.unsafeDataAsMap v))
      amount    = BI.snd (BI.head (BI.unsafeDataAsMap adaTokens))
   in decode @Integer (Encoded amount)
```

## When it applies

- Reading lovelace from a `TxOut` value (an input being spent, an output being produced). ADA is present and first.
- Any asset whose position is fixed by an invariant you can actually rely on.

## When it does not apply

- Mint values: ADA may be absent, and the first entry is not guaranteed to be ADA.
- Arbitrary assets at unknown positions. LinearVesting reads a vesting token by `(CurrencySymbol, TokenName)` taken from its datum, which needs the keyed lookup (see [bytestring-key-lookups.md](bytestring-key-lookups.md)).
- Any value not guaranteed to be canonical.

State the assumption in the function's name and haddock, and keep the keyed lookup for the general case.

## Measured effect

`two_party_escrow` (Plinth 1.65, Data-backed V3) reads lovelace on every input and every output. Same inliner budget, all 47 scenario checks passing:

| lovelace read | cpu_units.sum | total_fee |
| --- | ---: | ---: |
| keyed lookup (upstream `valueOf` shape) | 267.4M | 86,534 |
| positional | 228.0M | 73,594 |

That is 15% off cpu and total fee from the positional read alone. Against this repo's earlier `equalsData`-based local helper the gap was larger, but part of that was the helper being heavier than upstream rather than the positional read itself.

## Upstream

`lovelaceValueOf` in `plutus-ledger-api` uses the keyed lookup and has no positional fast path (both the Scott and Data-backed modules). Filed as IntersectMBO/plutus-private#2304. Once a library positional accessor exists for the Data-backed `Value`, the local `adaOf` can be removed in its favour.

## Used by

- `TwoPartyEscrow`: `lovelaceOf` reads via `adaOf`.
