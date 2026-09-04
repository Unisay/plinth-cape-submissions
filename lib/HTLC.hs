{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QualifiedDo #-}
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
{- Hand-swept Plinth inliner budget: inlining is what collapses the
'Validator' monad and fuses the decode walks. Swept against the CAPE
objective (happy-path-only total_fee_lovelace) on plutus 1.67, measured
on CAPE's 1.63 production evaluator:

  uncond    total_fee  exec    refscript  script_size
  ────────  ─────────  ──────  ─────────  ───────────
  1 (dflt)     26 546  16 736      9 810          654
  8            26 302  16 612      9 690          646
  12           26 144  16 529      9 615          641
  16–20        25 292  15 947      9 345          623
  24 ◀         24 498  15 393      9 105          607
  25–26        25 231  15 061     10 170          678
  27           31 817  14 477     17 340        1 156
  32           32 517  14 562     17 955        1 197
  40–48        33 432  14 562     18 870        1 258

24 is a genuine local minimum, not a point on a slope: 25 and 26 were
probed explicitly and both cost more, because that is where the artifact
starts growing again (607 → 678 bytes) while execution barely improves.
Past 26 the inliner duplicates matcher code and the reference-script fee
roughly doubles.

The old value of 32 was chosen under 1.65, already ranking by fee — it did
not survive the compiler bump rather than having been picked on the wrong
axis. Re-sweep after structural changes, and on every plutus bump.

The callsite axis, swept second with uncond held at 24:

  callsite    total_fee  exec    refscript  script_size
  ──────────  ─────────  ──────  ─────────  ───────────
  5 (dflt)–12   24 498  15 393      9 105          607
  16            25 292  15 947      9 345          623
  18            25 170  15 585      9 585          639
  19–24 ◀       24 376  15 031      9 345          623
  25–26         28 800  14 865     13 935          929
  28            29 258  14 978     14 280          952
  32            33 194  14 729     18 465        1 231
  40            33 524  14 729     18 795        1 253

Then uncond again with callsite at 21, which moved nothing here: the default
costs 25 009, 8 costs 24 534, and 12 through 24 all sit at 24 376. 24 is kept
because it is already the committed value and sits on that plateau.

Note [Callsite growth is not dominated by uncond] applies: the earlier belief
that this axis saturates and can be left alone was recorded against an older
compiler, and it is false at 1.67. See "Plinth.Decoder.Named" for the shared
finding — all three decoder-DSL validators reach their optimum at the same
callsite value, which is what makes it a property of the DSL rather than of
any one validator.
-}
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=24 #-}
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-callsite-growth=21 #-}

{- |
The HTLC validator, written in @do@-notation on the early-termination
'Validator' monad (see "Plinth.Validator", Note [Zero-cost Validator monad]).
The whole validator lives here; only the generic, reusable DSL is separate.

Both monads' @do@ blocks are @QualifiedDo@: @V.do@ sequences 'Validator'
stages, @N.do@ builds "Plinth.Decoder.Named" walk regions; ordinary @if@ and
literals are untouched.

Each 'ScriptContext'/datum/'TxInfo' field is decoded with a single @Constr@ walk,
and a value that is only compared is never decoded — see
Note [Decoding ScriptContext without redundancy].
-}
module HTLC (
  htlcValidatorCode,
  htlcValidator,
) where

import HTLC.Fixture qualified as HTLC
import Plinth.Decoder.Named (
  atField,
  field,
  fields,
  walk,
  walkRaw,
  yield,
 )
import Plinth.Decoder.Named qualified as N
import Plinth.Decoder.Named.ScriptContext (
  AddressCredential,
  BoundClosure,
  BoundExtended,
  FiniteValue,
  IntervalFrom,
  IntervalTo,
  JustValue,
  PubKeyCredentialHash,
  ScriptContextRedeemer,
  ScriptContextScriptInfo,
  ScriptContextTxInfo,
  SpendingScriptDatum,
  SpendingScriptOutRef,
  TxInInfoOutRef,
  TxInInfoResolved,
  TxInfoInputs,
  TxInfoSignatories,
  TxInfoValidRange,
  TxOutAddress,
 )
import Plinth.Encoded (
  Encoded,
  anyE,
  countE,
  decode,
  encoded,
  findE,
  tagOf,
 )
import Plinth.Validator (
  Validator,
  runValidator,
  validate,
 )
import Plinth.Validator qualified as V
import PlutusLedgerApi.Data.V3 (
  Address,
  Credential,
  Datum (getDatum),
  LowerBound,
  POSIXTime (getPOSIXTime),
  POSIXTimeRange,
  PubKeyHash,
  Redeemer (getRedeemer),
  ScriptContext,
  ScriptInfo,
  TxInInfo,
  TxInfo,
  TxOutRef,
  UpperBound,
 )
import PlutusTx qualified
import PlutusTx.Code (CompiledCode)
import PlutusTx.Data.List (List)
import PlutusTx.Prelude

--------------------------------------------------------------------------------
-- Validator -------------------------------------------------------------------

htlcValidatorCode :: CompiledCode (BuiltinData -> BuiltinUnit)
htlcValidatorCode = $$(PlutusTx.compile [||htlcValidator||])

htlcValidator :: BuiltinData -> BuiltinUnit
htlcValidator ctxData = runValidator V.do
  (txInfo, redeemer, scriptInfo) <-
    walkRaw @ScriptContext ctxData
      $ fields
        @( ScriptContextTxInfo
         , ScriptContextRedeemer
         , ScriptContextScriptInfo
         )
  case unsafeFromBuiltinData (getRedeemer (decode redeemer)) of
    HTLC.Claim preimage -> validateClaim txInfo scriptInfo preimage
    HTLC.Refund -> validateRefund txInfo scriptInfo

validateClaim ::
  Encoded TxInfo -> Encoded ScriptInfo -> BuiltinByteString -> Validator ()
validateClaim txInfo scriptInfo preimage = V.do
  (ownRef, datumJust) <-
    walk scriptInfo (fields @(SpendingScriptOutRef, SpendingScriptDatum))
  htlcDatum <- walk datumJust N.do
    datum <- field @JustValue
    yield (encoded (unsafeFromBuiltinData (getDatum (decode datum)) :: HTLC.Datum))
  (recipientAddr, storedHash, timeoutT) <-
    walk
      htlcDatum
      (fields @(HTLC.Recipient, HTLC.SecretHash, HTLC.Timeout))
  validate "Preimage does not match stored hash" do
    sha2_256 preimage == decode storedHash
  (validRange, signatories) <-
    walk txInfo (fields @(TxInfoValidRange, TxInfoSignatories))
  validate "Missing recipient signature" do
    signedBy recipientAddr signatories
  validate "Claim not permitted at or after timeout" do
    getPOSIXTime (decode timeoutT) > upperBoundTime validRange
  validate "Double satisfaction" do
    countOwnScriptInputs (atField @TxInfoInputs txInfo) ownRef == 1

validateRefund :: Encoded TxInfo -> Encoded ScriptInfo -> Validator ()
validateRefund txInfo scriptInfo = V.do
  (ownRef, datumJust) <-
    walk scriptInfo (fields @(SpendingScriptOutRef, SpendingScriptDatum))
  htlcDatum <- walk datumJust N.do
    datum <- field @JustValue
    yield (encoded (unsafeFromBuiltinData (getDatum (decode datum)) :: HTLC.Datum))
  (payerAddr, timeoutT) <-
    walk htlcDatum (fields @(HTLC.Payer, HTLC.Timeout))
  (validRange, signatories) <-
    walk txInfo (fields @(TxInfoValidRange, TxInfoSignatories))
  validate "Missing payer signature" do
    signedBy payerAddr signatories
  validate "Refund not permitted until after timeout" do
    lowerBoundTime validRange > getPOSIXTime (decode timeoutT)
  validate "Double satisfaction" do
    countOwnScriptInputs (atField @TxInfoInputs txInfo) ownRef == 1

--------------------------------------------------------------------------------
-- Decoding ---------------------------------------------------------------------

{- Note [Decoding ScriptContext without redundancy]
Each field is decoded at most once, and a value that is only compared is never
decoded structurally. Since CAPE metrics schema 2.0.0 only the ACCEPT-path
evaluations are scored — reject paths still must reject, but their cost is
free — so the decode plan serves the happy path alone. The measured tradeoffs:

  * one 'fields' region extracts a @Constr@'s demanded fields in ONE spine
    walk; lazy per-field @asData@ selectors re-walk the spine once PER
    demanded field, and at the swept (low) inline budget they additionally
    stay behind unreduced generic matchers. Under happy-path-only scoring the
    per-path 'HTLCDatum' regions (claim: recipient/secretHash/timeout,
    refund: payer/timeout) replaced the lazy selectors for −3 936
    total_fee_lovelace; the earlier lazy-selector advantage existed only
    because the old aggregation also summed the abort paths, which skip
    fields their failing guard never reaches.
  * regions do not pay off on 2-field nodes: walking the interval bound with
    a @(BoundExtended, BoundClosure)@ region instead of the two 'atField'
    projections measured +1 260 — the repeated @unConstrData@ of the
    projection pair is already CSE-merged, and the region machinery costs
    size.
  * grabbing the inputs list en route in the @TxInfo@ region instead of the
    'atField' in the final guard is cost-identical (the guard's walk is
    CSE-merged with the region's), so the guard keeps the local spelling.
  * bundling a late-needed value into an early continuation tuple lengthens
    its decode into a re-forceable @delay@ (CEK does not memoise
    @force (delay …)@) — an abort then re-runs that prefix twice. Aborts are
    no longer scored, but the shared-cursor regions avoid it for free.
-}

--------------------------------------------------------------------------------
-- Guard predicates -----------------------------------------------------------

-- | True iff the address's payment 'PubKeyHash' is among the signatories.
signedBy :: Encoded Address -> Encoded (List PubKeyHash) -> Bool
signedBy addr signatories =
  let cred = atField @AddressCredential addr
   in if tagOf cred == 0
        then anyE (== atField @PubKeyCredentialHash cred) signatories
        else traceError "Expected PubKeyCredential address"

--------------------------------------------------------------------------------
-- Other helper functions -----------------------------------------------------

-- | Earliest time in a validity range (finite lower bound, @+1@ if exclusive).
lowerBoundTime :: Encoded POSIXTimeRange -> Integer
lowerBoundTime range =
  boundTimeLower
    1
    "Lower bound of valid range must be finite"
    (atField @IntervalFrom range)

-- | Latest time in a validity range (finite upper bound, @-1@ if exclusive).
upperBoundTime :: Encoded POSIXTimeRange -> Integer
upperBoundTime range =
  boundTimeUpper
    (negate 1)
    "Upper bound of valid range must be finite"
    (atField @IntervalTo range)

-- | The time of a finite lower interval bound, @+@'openAdj' when exclusive.
boundTimeLower ::
  Integer -> BuiltinString -> Encoded (LowerBound POSIXTime) -> Integer
boundTimeLower openAdj msg bound =
  let ext = atField @BoundExtended bound
   in if tagOf ext == 1
        then
          let t = getPOSIXTime (decode (atField @FiniteValue ext))
           in if tagOf (atField @BoundClosure bound) == 1
                then t
                else t + openAdj
        else traceError msg

-- | The time of a finite upper interval bound, @+@'openAdj' when exclusive.
boundTimeUpper ::
  Integer -> BuiltinString -> Encoded (UpperBound POSIXTime) -> Integer
boundTimeUpper openAdj msg bound =
  let ext = atField @BoundExtended bound
   in if tagOf ext == 1
        then
          let t = getPOSIXTime (decode (atField @FiniteValue ext))
           in if tagOf (atField @BoundClosure bound) == 1
                then t
                else t + openAdj
        else traceError msg

-- | Count the transaction inputs at the own input's payment credential.
countOwnScriptInputs :: Encoded (List TxInInfo) -> Encoded TxOutRef -> Integer
countOwnScriptInputs inputs ownRef =
  let ownCred =
        inputCredential
          ( findE
              "Own input not found"
              (\i -> atField @TxInInfoOutRef i == ownRef)
              inputs
          )
   in countE (\i -> inputCredential i == ownCred) inputs

-- | The payment credential of a tx input; never decoded, only compared.
inputCredential :: Encoded TxInInfo -> Encoded Credential
inputCredential i =
  atField @AddressCredential (atField @TxOutAddress (atField @TxInInfoResolved i))
