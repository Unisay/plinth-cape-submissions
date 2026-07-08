-- CPP only selects the per-build inliner budget below.
{-# LANGUAGE CPP #-}
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

{- Hand-swept inline-unconditional-growth, re-swept for happy-path
   total_fee_lovelace after moving 'assetAmount' to the bytestring-keyed
   'lookupBytesE' (equalsByteString on the unwrapped Value keys instead of
   equalsData on the whole key):
     budget    fee
     1 (dflt)  62366
     16        62494
     20        60631
     24-28     58343   <- optimum (kept 24; -4023 vs default, and -705 vs the
     32-36     58471      earlier equalsData lookupE at its own optimum 59048)
     40-44     58343
   Re-sweep after structural changes.

   The PREVIEW build (datatypes=BuiltinCasing + dropList skip emission)
   inverts the tradeoff: builtin casing needs no inliner-driven matcher
   repair, so a raised budget only duplicates code. Swept separately (preview
   evaluator, happy-path fee):
     budget    fee
     1-16      48971   <- optimum plateau, default included (kept 12 for
     20        51119      symmetry with the prod branch; the pragma is inert
     24        51201      here. -834 vs the earlier equalsData lookupE 49805) -}
#ifdef PREVIEW
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=12 #-}
#else
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=24 #-}
#endif

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

import LinearVesting.Fixture (VestingDatum)
import Plinth.Decoder.Named (
  FieldAt,
  N0,
  N1,
  N2,
  N3,
  N4,
  N5,
  N6,
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
  CurrencySymbol,
  Datum (getDatum),
  LowerBound,
  POSIXTime (getPOSIXTime),
  POSIXTimeRange,
  PubKeyHash,
  ScriptContext,
  ScriptInfo,
  TokenName,
  TxInInfo,
  TxInfo,
 )
import PlutusTx qualified
import PlutusTx.Code (CompiledCode)
import PlutusTx.Data.List (List)
import PlutusTx.Prelude

--------------------------------------------------------------------------------
-- Layout ------------------------------------------------------------------------

-- The 'FieldAt' layout of 'VestingDatum' (Constr tag 0), one tag per record
-- selector; declared here, next to the only consumer.

data VestingBeneficiary

data VestingAsset

data VestingTotalQty

data VestingPeriodStart

data VestingPeriodEnd

data VestingFirstUnlockAfter

data VestingTotalInstallments

instance FieldAt VestingBeneficiary VestingDatum N0 Address

instance FieldAt VestingAsset VestingDatum N1 (CurrencySymbol, TokenName)

instance FieldAt VestingTotalQty VestingDatum N2 Integer

instance FieldAt VestingPeriodStart VestingDatum N3 Integer

instance FieldAt VestingPeriodEnd VestingDatum N4 Integer

instance FieldAt VestingFirstUnlockAfter VestingDatum N5 Integer

instance FieldAt VestingTotalInstallments VestingDatum N6 Integer

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
    walkRaw @VestingDatum datumBd N.do
      b <- field @VestingBeneficiary
      a <- field @VestingAsset
      q <- field @VestingTotalQty
      s <- field @VestingPeriodStart
      e <- field @VestingPeriodEnd
      u <- field @VestingFirstUnlockAfter
      n <- field @VestingTotalInstallments
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
    walkRaw @VestingDatum (getDatum (decode datum))
      $ fields @(VestingBeneficiary, VestingPeriodEnd)
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
