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
schema-2.0.0 objective (happy-path-only total_fee_lovelace); the old
optimum of 52 was measured under the summed accept+reject aggregation
and no longer wins. Re-sweep after structural changes.

  budget   default  16–22   24–30   32–40   44      52
  fee      35 414   34 175  31 826  31 832  33 451  38 776
                            ^ optimum (Δ −3 588 vs default)
-}
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=24 #-}

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
module HTLC.Monadic (
  htlcValidatorCode,
  htlcValidator,
) where

import HTLC (
  HTLCDatum,
  pattern Claim,
  pattern Refund,
 )
import Plinth.Decoder.Named (
  FieldAt,
  N0,
  N1,
  N2,
  N3,
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
    Claim preimage -> validateClaim txInfo scriptInfo preimage
    Refund -> validateRefund txInfo scriptInfo

validateClaim ::
  Encoded TxInfo -> Encoded ScriptInfo -> BuiltinByteString -> Validator ()
validateClaim txInfo scriptInfo preimage = V.do
  (ownRef, datumJust) <-
    walk scriptInfo (fields @(SpendingScriptOutRef, SpendingScriptDatum))
  htlcDatum <- walk datumJust N.do
    datum <- field @JustValue
    yield (encoded (unsafeFromBuiltinData (getDatum (decode datum)) :: HTLCDatum))
  (recipientAddr, storedHash, timeoutT) <-
    walk htlcDatum (fields @(DatumRecipient, DatumSecretHash, DatumTimeout))
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
    yield (encoded (unsafeFromBuiltinData (getDatum (decode datum)) :: HTLCDatum))
  (payerAddr, timeoutT) <-
    walk htlcDatum (fields @(DatumPayer, DatumTimeout))
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
    refund: payer/timeout) plus the budget re-sweep replaced the lazy
    selectors for −6 950 total_fee_lovelace on this line; the earlier
    lazy-selector advantage existed only because the old aggregation also
    summed the abort paths, which skip fields their failing guard never
    reaches. (On the 1.65 line the same region spelling was also measured
    against 2-field nodes and the redeemer dispatch — both regressed there;
    those spellings are kept as-is here.)
  * bundling a late-needed value into an early continuation tuple lengthens
    its decode into a re-forceable @delay@ (CEK does not memoise
    @force (delay …)@) — an abort then re-runs that prefix twice. Aborts are
    no longer scored, but the shared-cursor regions avoid it for free.
-}

--------------------------------------------------------------------------------
-- 'HTLCDatum' layout ----------------------------------------------------------

-- The 'FieldAt' layout of 'HTLC.HTLCDatum', audited against its
-- 'PlutusTx.AsData.asData' declaration (payer, recipient, secretHash, timeout).

data DatumPayer

data DatumRecipient

data DatumSecretHash

data DatumTimeout

instance FieldAt DatumPayer HTLCDatum N0 Address

instance FieldAt DatumRecipient HTLCDatum N1 Address

instance FieldAt DatumSecretHash HTLCDatum N2 BuiltinByteString

instance FieldAt DatumTimeout HTLCDatum N3 POSIXTime

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
