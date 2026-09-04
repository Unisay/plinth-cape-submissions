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

{- Per-module Plinth inliner tuning: callsite only. The plugin default for
   inline-unconditional-growth (1) is on the optimal plateau for the CAPE
   objective, so that option stays unset; inline-callsite-growth is not, and
   is pinned at 21.

   Swept 1-D on uncond against total_fee_lovelace (plutus 1.67, measured on
   CAPE's 1.63 production evaluator, scripts/sweep-inline.sh):

     uncond      total_fee  exec    refscript  script_size
     ──────────  ─────────  ──────  ─────────  ───────────
     1 (dflt) ◀     51 656  37 646     14 010          934
     8              51 784  37 729     14 055          937
     12–16          51 656  37 646     14 010          934
     20             51 933  35 583     16 350        1 090
     24             52 241  35 666     16 575        1 105
     27             55 642  35 167     20 475        1 365
     32             59 285  33 755     25 530        1 702
     40–48          60 245  33 755     26 490        1 766

   Execution falls monotonically as the budget rises, but never fast enough
   to pay for the bytes: from 16 to 48 it buys 3 891 lovelace of execution
   for 12 480 of reference-script fee. The blip at 8 (+128) is reproducible,
   not noise — the measurement is deterministic — but too small to matter.

   The previous value of 24 was chosen under 1.65, already ranking by fee;
   it did not survive the compiler bump. Dropping it saves 585 lovelace
   (52 241 → 51 656, −1.1%). Re-sweep after structural changes, and on every
   plutus bump.

   The callsite axis, swept second with uncond left at the default. This is
   the axis the 1-D sweep never touched, and it is worth 1 758 lovelace here:

     callsite      total_fee  exec    refscript  script_size
     ────────────  ─────────  ──────  ─────────  ───────────
     1                52 373  39 038     13 335          889
     3–8              51 784  37 729     14 055          937
     5 (dflt)         51 656  37 646     14 010          934
     12–18            50 882  37 037     13 845          923
     19–22 ◀          49 898  36 248     13 650          910
     23–28            52 459  35 749     16 710        1 114
     32               56 270  35 375     20 895        1 393
     40               60 876  34 461     26 415        1 761

   Then uncond again with callsite at 21: the default through 16 all measure
   49 898, and 20 upward regress, so the default stays. 21 clears the "keep an
   option only if the default provably regresses" bar by 1 758 lovelace, which
   is the whole margin — unlike the old uncond=24, this one earns its place.

   Note [Callsite growth is not dominated by uncond] applies: the belief that
   this axis saturates and can be left alone came from an older compiler and is
   false at 1.67. See "Plinth.Decoder.Named" — all three decoder-DSL validators
   reach their optimum at the same callsite value. -}
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-callsite-growth=21 #-}

{- |
The linear-vesting validator, written in @do@-notation on the
early-termination 'Validator' monad, with all decoding going through the
"Plinth.Decoder.Named" walk regions — the same recipe as "HTLC.Monadic".

Everything stays 'Encoded' until a guard actually needs a number: the
beneficiary is only compared against the signatories, the vesting asset's
currency symbol and token name are only compared against 'Value' keys, and
the datum-preservation check is one 'equalsData' — none of them is ever
structurally decoded. Only the five schedule integers are.
-}
module LinearVesting (
  linearVestingValidatorCode,
  linearVestingValidator,
) where

import LinearVesting.Fixture qualified as Vesting
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
  JustValue,
  PairFst,
  PairSnd,
  PubKeyCredentialHash,
  ScriptContextRedeemer,
  ScriptContextScriptInfo,
  ScriptContextTxInfo,
  SpendingScriptDatum,
  SpendingScriptOutRef,
  TxInInfoOutRef,
  TxInInfoResolved,
  TxInfoInputs,
  TxInfoOutputs,
  TxInfoSignatories,
  TxInfoValidRange,
  TxOutAddress,
  TxOutDatum,
  TxOutValue,
  assetAmount,
 )
import Plinth.Encoded (
  Encoded,
  anyE,
  countE,
  decode,
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
  ScriptContext,
  ScriptInfo,
  TxInInfo,
  TxInfo,
 )
import PlutusTx qualified
import PlutusTx.Code (CompiledCode)
import PlutusTx.Data.List (List)
import PlutusTx.Prelude

--------------------------------------------------------------------------------
-- Validator -------------------------------------------------------------------

linearVestingValidatorCode :: CompiledCode (BuiltinData -> BuiltinUnit)
linearVestingValidatorCode = $$(PlutusTx.compile [||linearVestingValidator||])

linearVestingValidator :: BuiltinData -> BuiltinUnit
linearVestingValidator ctxData = runValidator V.do
  (txInfo, redeemer, scriptInfo) <-
    walkRaw @ScriptContext ctxData
      $ fields
        @( ScriptContextTxInfo
         , ScriptContextRedeemer
         , ScriptContextScriptInfo
         )
  -- 'Redeemer' is a newtype over its content, so the tag read here is the
  -- 'VestingRedeemer' constructor tag; a non-Constr redeemer fails right here.
  let redeemerTag = tagOf redeemer
  if
    | redeemerTag == 0 -> validatePartialUnlock txInfo scriptInfo
    | redeemerTag == 1 -> validateFullUnlock txInfo scriptInfo
    | otherwise -> traceError "Invalid redeemer"

validatePartialUnlock :: Encoded TxInfo -> Encoded ScriptInfo -> Validator ()
validatePartialUnlock txInfo scriptInfo = V.do
  (ownRef, datumJust) <-
    walk scriptInfo (fields @(SpendingScriptOutRef, SpendingScriptDatum))
  datum <- walk datumJust (field @JustValue)
  let datumBd = getDatum (decode datum)
  -- One region for all seven datum fields: the partial-unlock guards and the
  -- quantity arithmetic reach every field on the happy path, so a single
  -- spine walk beats the earlier beneficiary/firstUnlockAfter + rest split
  -- (measured -119 fee under happy-path-only scoring).
  ( beneficiary
    , asset
    , totalQty
    , periodStart
    , periodEnd
    , firstUnlockAfter
    , installments
    ) <-
    walkRaw @Vesting.Datum datumBd N.do
      b <- field @Vesting.Beneficiary
      a <- field @Vesting.Asset
      q <- field @Vesting.TotalQty
      s <- field @Vesting.PeriodStart
      e <- field @Vesting.PeriodEnd
      u <- field @Vesting.FirstUnlockAfter
      n <- field @Vesting.Installments
      yield (b, a, q, s, e, u, n)
  (validRange, signatories) <-
    walk txInfo (fields @(TxInfoValidRange, TxInfoSignatories))
  validate "Missing beneficiary signature" do
    signedBy beneficiary signatories
  let currentTime = lowerBoundTime validRange
  validate "Unlock not permitted until firstUnlockPossibleAfter time" do
    currentTime > decode firstUnlockAfter
  let inputs = atField @TxInfoInputs txInfo
  let ownInput =
        findE
          "Own input not found"
          (\i -> atField @TxInInfoOutRef i == ownRef)
          inputs
  let ownOut = atField @TxInInfoResolved ownInput
  let ownAddress = atField @TxOutAddress ownOut
  let continuingOut =
        findE
          "Own output not found"
          (\o -> atField @TxOutAddress o == ownAddress)
          (atField @TxInfoOutputs txInfo)
  validate "Datum Modification Prohibited" do
    atField @TxOutDatum ownOut == atField @TxOutDatum continuingOut
  (cs, tn) <- walk asset (fields @(PairFst, PairSnd))
  let newRemainingQty = assetAmount (atField @TxOutValue continuingOut) cs tn
  validate "Zero remaining assets not allowed" do
    newRemainingQty > 0
  validate "Remaining asset is not decreasing" do
    newRemainingQty < assetAmount (atField @TxOutValue ownOut) cs tn
  let totalInstallments = decode installments
  let vestingPeriodEnd = decode periodEnd
  let vestingPeriodLength = vestingPeriodEnd - decode periodStart
  let vestingTimeRemaining = vestingPeriodEnd - currentTime
  let timeBetweenTwoInstallments = divCeil vestingPeriodLength totalInstallments
  let futureInstallments = divCeil vestingTimeRemaining timeBetweenTwoInstallments
  let expectedRemainingQty =
        divCeil (futureInstallments * decode totalQty) totalInstallments
  validate "Mismatched remaining asset" do
    expectedRemainingQty == newRemainingQty
  validate "Double satisfaction" do
    let ownCredential = atField @AddressCredential ownAddress
    countE (\i -> inputCredential i == ownCredential) inputs == 1

validateFullUnlock :: Encoded TxInfo -> Encoded ScriptInfo -> Validator ()
validateFullUnlock txInfo scriptInfo = V.do
  datumJust <- walk scriptInfo (field @SpendingScriptDatum)
  datum <- walk datumJust (field @JustValue)
  (beneficiary, periodEnd) <-
    walkRaw @Vesting.Datum (getDatum (decode datum))
      $ fields @(Vesting.Beneficiary, Vesting.PeriodEnd)
  (validRange, signatories) <-
    walk txInfo (fields @(TxInfoValidRange, TxInfoSignatories))
  validate "Missing beneficiary signature" do
    signedBy beneficiary signatories
  validate "Unlock not permitted until vestingPeriodEnd time" do
    lowerBoundTime validRange > decode periodEnd

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

-- | Integer ceiling division: divCeil(x, y) = 1 + ((x - 1) / y)
divCeil :: Integer -> Integer -> Integer
divCeil x y = 1 + divide (x - 1) y

-- | Earliest time in a validity range (finite lower bound, @+1@ if exclusive).
lowerBoundTime :: Encoded POSIXTimeRange -> Integer
lowerBoundTime range =
  boundTime
    1
    "Lower bound of valid range must be finite"
    (atField @IntervalFrom range)

-- | The time of a finite lower interval bound, @+@'openAdj' when exclusive.
boundTime ::
  Integer -> BuiltinString -> Encoded (LowerBound POSIXTime) -> Integer
boundTime openAdj msg bound =
  let ext = atField @BoundExtended bound
   in if tagOf ext == 1
        then
          let t = getPOSIXTime (decode (atField @FiniteValue ext))
           in if tagOf (atField @BoundClosure bound) == 1
                then t
                else t + openAdj
        else traceError msg

-- | The payment credential of a tx input; never decoded, only compared.
inputCredential :: Encoded TxInInfo -> Encoded Credential
inputCredential i =
  atField @AddressCredential (atField @TxOutAddress (atField @TxInInfoResolved i))
