# Non-redundant data decoding

Decode a `ScriptContext` the way the `Validator` monad and `Decoder.Named` walk regions in this repo do: touch each `Constr` spine once, keep values in their raw `BuiltinData` form (`Encoded a`), and pay for a structural decode only where the validator actually needs a Haskell value.

## The ideas

Values stay raw until proven otherwise. `Encoded a` is a newtype over `BuiltinData`. Equality on it is one `equalsData` on the raw bytes, with no field decode. Comparing a context value against a compile-time constant is `value == encoded Fixed.constant`: one builtin, neither side decoded. Fixed parties, prices and the script's own credential become raw byte comparisons.

Decode a spine once, not per field. Reading N fields of a `Constr` with N separate `atField` calls re-walks the spine from the top N times. On a large structure such as `TxInfo` that is a measured regression. A walk region takes a tuple of the fields it wants and pulls them out in one pass:

```haskell
(inputs, outputs, signatories) <-
  walk txInfo (fields @(TxInfoInputs, TxInfoOutputs, TxInfoSignatories))
```

Decode only at the edge. `decode` marks the single place a structural `unsafeFromBuiltinData` happens. Integers, interval bounds and similar leaves are decoded where used; everything else stays `Encoded` and is compared, folded, or checked by constructor tag without ever becoming a Haskell value.

Check the tag, do not decode the sum. `tagOf` reads a `Constr`'s index with one `unConstrData`. State-machine states and `Maybe` / `OutputDatum`-style wrappers branch on the tag instead of decoding the payload.

## When to be careful

- Under `Strict` or `StrictData`, per-field laziness is lost. Reintroduce it with `~` patterns where an abort path would otherwise force fields it never needs.
- A small struct on an abort-heavy path can prefer lazy per-field access over one shared walk; a large struct prefers the shared walk. Measure per case rather than assuming.

## Measured effect

This style is the basis of the monadic ports in this repo (HTLC, LinearVesting, TwoPartyEscrow), which cut total fee by well over half against the `asData` / `getContinuingOutputs` / `valuePaidTo` baselines. Each validator's module header records its own numbers.

## Used by

- `HTLC`, `LinearVesting`, `TwoPartyEscrow`, all built on `Plinth.Validator` and `Plinth.Decoder.Named`.
