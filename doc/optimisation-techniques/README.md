# Optimisation techniques

Measured techniques for writing cheaper Plinth validators, extracted from the submissions in this repo. Each file documents one technique: what it is, when it applies (and when it does not), why it is safe, and the measured effect.

The point is to write the rationale once. A validator can point a reader here instead of repeating the explanation:

```haskell
lovelaceOf o = adaOf (atField @TxOutValue o)  -- doc/optimisation-techniques/positional-value-reads.md
```

All numbers come from `cape submission measure` on the committed `.uplc`. Measurement is the only source of truth: an "obvious" optimisation often does nothing once the plugin's inliner has had its way, and sometimes regresses. Measure before and after, one change at a time.

## Documented

- [positional-value-reads.md](positional-value-reads.md): read a known asset's quantity from a canonical `Value` by position instead of a keyed lookup.
- [bytestring-key-lookups.md](bytestring-key-lookups.md): when a positional read does not apply, look up a `Value` key by comparing the unwrapped bytes with `equalsByteString` instead of `equalsData` on the whole key.
- [non-redundant-data-decoding.md](non-redundant-data-decoding.md): the `Validator` monad and `Decoder.Named` walk regions: touch each `Constr` spine once, keep values raw, decode only where needed.

## To document

Techniques already used in the submissions that still need a write-up:

- [ ] Compare against compile-time constants as raw `Data` (`encoded` + `equalsData`) instead of decoding and comparing structured values.
- [ ] Identify "this script" by payment credential, not the full `Address` (correctness and cost).
- [ ] Single-pass list traversal and fold fusion (`findUniqueE`; folding two independent checks in one pass over the outputs).
- [ ] Share one struct spine walk across several fields (`fields @(...)`) rather than a separate `atField` per field, which re-walks a large `Constr`.
- [ ] Drop `not` from boolean guards by flipping the comparison.
- [ ] Per-module inliner budget sweep (`inline-unconditional-growth`), recorded as a budget-to-fee table with the chosen optimum.
