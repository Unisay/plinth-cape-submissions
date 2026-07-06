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
{- Hand-swept Plinth inliner budget (sweep table in git history): inlining is
what collapses the 'Validator' monad and fuses the decode walks. The default
budget declines them: without this pragma the term is smaller (749 vs 1135
bytes) but every claim/refund scenario executes more CPU/mem, netting
total_fee_lovelace 82 930 vs 65 538. Re-sweep after structural changes.
-}
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=52 #-}

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

import HTLC.Fixture (
  payer,
  recipient,
  secretHash,
  timeout,
  pattern Claim,
  pattern Refund,
 )
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
    Claim preimage -> validateClaim txInfo scriptInfo preimage
    Refund -> validateRefund txInfo scriptInfo

validateClaim ::
  Encoded TxInfo -> Encoded ScriptInfo -> BuiltinByteString -> Validator ()
validateClaim txInfo scriptInfo preimage = V.do
  (ownRef, datumJust) <-
    walk scriptInfo (fields @(SpendingScriptOutRef, SpendingScriptDatum))
  htlcDatum <- walk datumJust N.do
    datum <- field @JustValue
    yield (unsafeFromBuiltinData (getDatum (decode datum)))
  validate "Preimage does not match stored hash" do
    sha2_256 preimage == secretHash htlcDatum
  (validRange, signatories) <-
    walk txInfo (fields @(TxInfoValidRange, TxInfoSignatories))
  validate "Missing recipient signature" do
    signedBy (encoded (recipient htlcDatum)) signatories
  validate "Claim not permitted at or after timeout" do
    getPOSIXTime (timeout htlcDatum) > upperBoundTime validRange
  validate "Double satisfaction" do
    countOwnScriptInputs (atField @TxInfoInputs txInfo) ownRef == 1

validateRefund :: Encoded TxInfo -> Encoded ScriptInfo -> Validator ()
validateRefund txInfo scriptInfo = V.do
  (ownRef, datumJust) <-
    walk scriptInfo (fields @(SpendingScriptOutRef, SpendingScriptDatum))
  htlcDatum <- walk datumJust N.do
    datum <- field @JustValue
    yield (unsafeFromBuiltinData (getDatum (decode datum)))
  (validRange, signatories) <-
    walk txInfo (fields @(TxInfoValidRange, TxInfoSignatories))
  validate "Missing payer signature" do
    signedBy (encoded (payer htlcDatum)) signatories
  validate "Refund not permitted until after timeout" do
    lowerBoundTime validRange > getPOSIXTime (timeout htlcDatum)
  validate "Double satisfaction" do
    countOwnScriptInputs (atField @TxInfoInputs txInfo) ownRef == 1

--------------------------------------------------------------------------------
-- Decoding ---------------------------------------------------------------------

{- Note [Decoding ScriptContext without redundancy]
Each field is decoded at most once and only when a guard actually reaches it, and a
value that is only compared is never decoded structurally. The tradeoffs:

  * a single-walk @case@ extracts ALL of a @Constr@'s fields in one spine walk;
    lazy per-field @asData@ selectors re-walk the spine once PER demanded field but
    skip fields no guard reaches. Which wins depends on size and abort paths: for
    the large 'TxInfo' the per-field re-walk regresses badly (+63% cpu_sum), so a
    single hand-walk is used; for the small 'HTLCDatum' (4 fields) lazy per-field
    selectors win, because abort paths (bad preimage / missing sig / timeout) never
    extract the fields their failing guard did not reach.
  * bundling a late-needed value into an early continuation tuple lengthens its
    decode into a re-forceable @delay@ (CEK does not memoise @force (delay …)@),
    so an abort re-runs that prefix TWICE — the "abort doubling".
  * region placement is demand knowledge and stays with the validator author:
    e.g. grabbing the inputs list in the early @TxInfo@ region instead of the
    final guard measures worse (+267 fee) — the many abort scenarios each pay
    an extra step to save the few last-guard scenarios a second
    @unConstrData@, and under CAPE's equal-weight sum the aborts win.
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
