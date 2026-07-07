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
{- Hand-swept inline-unconditional-growth against the CAPE schema-2.0.0
   objective (happy-path-only total_fee_lovelace); swept on this branch
   after the port from the 1.65 line:
     budget    fee
     default   120754
     24-26     114980
     27        112972
     28-29     111735   <- optimum (chosen 28; -9019, -7.5% vs default)
     30-32     114908   (script size jumps to 1988 B)
     36        115613
   Re-sweep after structural changes.
-}
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=28 #-}

{- |
The two-party-escrow validator on the 'Validator' monad and
"Plinth.Decoder.Named" walk regions — the "HTLC.Monadic" recipe, ported
from the Plinth 1.65 line.

The escrow parties, price and script address are compile-time fixture
constants, so every comparison against them is one 'equalsData' on raw
bytes: the datum's state is checked by constructor tag alone, payments are
summed by folding the outputs' raw lovelace entries ('foldE' +
'assetAmount') instead of decoding and unioning whole 'Value's the way
@valuePaidTo@ does, and an escrow input is recognised by its payment
credential equalling the script's own plus raw amount. The only structural
decodes left are the deposit-time integer and the interval bounds.
-}
module TwoPartyEscrow.Monadic (
  twoPartyEscrowValidatorCode,
  twoPartyEscrowValidator,
) where

import Plinth.Decoder.Named (
  FieldAt,
  N0,
  N1,
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
  OutputDatumDatum,
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
  Encoded (Encoded),
  anyE,
  decode,
  encoded,
  findE,
  foldE,
  tagOf,
 )
import Plinth.Validator (
  Validator,
  runValidator,
  validate,
 )
import Plinth.Validator qualified as V
import PlutusLedgerApi.Data.V3 (
  Credential,
  Datum (getDatum),
  Lovelace (getLovelace),
  LowerBound,
  POSIXTime (getPOSIXTime),
  POSIXTimeRange,
  Redeemer (getRedeemer),
  ScriptContext,
  ScriptInfo,
  TxInInfo,
  TxInfo,
  TxOut,
  UpperBound,
  adaSymbol,
  adaToken,
  pattern PubKeyCredential,
 )
import PlutusTx qualified
import PlutusTx.Code (CompiledCode)
import PlutusTx.Data.List (List)
import PlutusTx.Prelude
import TwoPartyEscrow.Fixture (EscrowDatum, EscrowState)
import TwoPartyEscrow.Fixture qualified as Fixed

--------------------------------------------------------------------------------
-- Layout ------------------------------------------------------------------------

-- The 'FieldAt' layout of 'EscrowDatum' (Constr tag 0); declared here, next
-- to the only consumer.

data EscrowDatumState

data EscrowDatumTime

instance FieldAt EscrowDatumState EscrowDatum N0 EscrowState

instance FieldAt EscrowDatumTime EscrowDatum N1 POSIXTime

--------------------------------------------------------------------------------
-- Validator -------------------------------------------------------------------

twoPartyEscrowValidatorCode :: CompiledCode (BuiltinData -> BuiltinUnit)
twoPartyEscrowValidatorCode = $$(PlutusTx.compile [||twoPartyEscrowValidator||])

twoPartyEscrowValidator :: BuiltinData -> BuiltinUnit
twoPartyEscrowValidator ctxData = runValidator V.do
  (txInfo, redeemer, scriptInfo) <-
    walkRaw @ScriptContext ctxData
      $ fields
        @( ScriptContextTxInfo
         , ScriptContextRedeemer
         , ScriptContextScriptInfo
         )
  -- The redeemer's content is a raw integer; anything else fails right here.
  let action :: Integer = unsafeFromBuiltinData (getRedeemer (decode redeemer))
  if
    | action == 0 -> validateDeposit txInfo
    | action == 1 -> validateAccept txInfo scriptInfo
    | action == 2 -> validateRefund txInfo scriptInfo
    | otherwise -> traceError "Invalid redeemer"

{- | Buyer deposits: exactly one script output of exactly the escrow price,
carrying a @Deposited@ datum stamped with the validity window's upper bound.
-}
validateDeposit :: Encoded TxInfo -> Validator ()
validateDeposit txInfo = V.do
  (validRange, signatories) <-
    walk txInfo (fields @(TxInfoValidRange, TxInfoSignatories))
  validate "Buyer signature missing" do
    anyE (== encoded Fixed.buyerKeyHash) signatories
  let escrowAddress = encoded Fixed.scriptAddr
  let outputs = atField @TxInfoOutputs txInfo
  let isScriptOutput o = atField @TxOutAddress o == escrowAddress
  let scriptOuts :: Integer =
        foldE (\n o -> if isScriptOutput o then n + 1 else n) 0 outputs
  validate "No script outputs created" do
    scriptOuts > 0
  validate "Too many script outputs created" do
    scriptOuts < 2
  let onlyOut = findE "No script outputs created" isScriptOutput outputs
  validate "Wrong script output amount" do
    lovelaceOf onlyOut == escrowPrice
  let outDatum = atField @TxOutDatum onlyOut
  validate "Invalid or missing deposit datum" do
    tagOf outDatum == 2 -- inline OutputDatum
  (state, depositTime) <-
    walkRaw @EscrowDatum
      (getDatum (decode (atField @OutputDatumDatum outDatum)))
      $ fields @(EscrowDatumState, EscrowDatumTime)
  validate "Invalid or missing deposit datum" do
    tagOf state == 0 -- Deposited
  validate "Invalid or missing deposit datum" do
    getPOSIXTime (decode depositTime) == upperBoundTime validRange

{- | Seller accepts: nothing stays at the script, the escrow price reaches
the seller, and a funded escrow input is actually being spent.
-}
validateAccept :: Encoded TxInfo -> Encoded ScriptInfo -> Validator ()
validateAccept txInfo scriptInfo = V.do
  (ownRef, datumJust) <-
    walk scriptInfo (fields @(SpendingScriptOutRef, SpendingScriptDatum))
  (state, _) <- escrowDatum datumJust
  validate "Accept only valid from Deposited state" do
    tagOf state == 0 -- Deposited
  signatories <- walk txInfo (field @TxInfoSignatories)
  validate "Seller signature missing" do
    anyE (== encoded Fixed.sellerKeyHash) signatories
  let inputs = atField @TxInfoInputs txInfo
  let ownInput =
        findE
          "Own input not found"
          (\i -> atField @TxInInfoOutRef i == ownRef)
          inputs
  let ownCred =
        atField @AddressCredential
          (atField @TxOutAddress (atField @TxInInfoResolved ownInput))
  let outputs = atField @TxInfoOutputs txInfo
  -- Compare the payment credential only: an output to the same credential with
  -- a staking part attached still locks funds under this validator and must be
  -- rejected as an incomplete withdrawal.
  validate "Incomplete withdrawal - funds remain in script" do
    not
      ( anyE
          (\o -> atField @AddressCredential (atField @TxOutAddress o) == ownCred)
          outputs
      )
  validate "No valid escrow deposit found in inputs" do
    anyE isEscrowInput inputs
  validate "Incorrect payment to seller" do
    lovelacePaidTo (PubKeyCredential Fixed.sellerKeyHash) outputs == escrowPrice

{- | Buyer refunds after the deadline: same shape as accept, but the funds
must come back to the buyer and only after @depositTime + refundTime@.
-}
validateRefund :: Encoded TxInfo -> Encoded ScriptInfo -> Validator ()
validateRefund txInfo scriptInfo = V.do
  datumJust <- walk scriptInfo (field @SpendingScriptDatum)
  (state, datumEsc) <- escrowDatum datumJust
  validate "Refund only valid from Deposited state" do
    tagOf state == 0 -- Deposited
  (validRange, signatories) <-
    walk txInfo (fields @(TxInfoValidRange, TxInfoSignatories))
  validate "Buyer signature missing" do
    anyE (== encoded Fixed.buyerKeyHash) signatories
  depositTime <- walk datumEsc (field @EscrowDatumTime)
  validate "Refund time not reached" do
    lowerBoundTime validRange
      > getPOSIXTime (decode depositTime)
      + getPOSIXTime Fixed.refundTime
  let inputs = atField @TxInfoInputs txInfo
  validate "No valid escrow deposit found in inputs" do
    anyE isEscrowInput inputs
  validate "Incorrect refund to buyer" do
    lovelacePaidTo
      (PubKeyCredential Fixed.buyerKeyHash)
      (atField @TxInfoOutputs txInfo)
      == escrowPrice

--------------------------------------------------------------------------------
-- Decoding helpers -------------------------------------------------------------

{- | Unwrap the spending datum's @Just@ once: the state field (checked by
'tagOf' at the call sites) plus the datum as an 'Encoded' 'EscrowDatum'
view, so a branch that later needs another field re-walks it without
re-unwrapping (the re-walk is CSE-merged; a (state, time) region measured
worse on the 1.65 line, +134).
-}
escrowDatum ::
  Encoded (Maybe Datum) -> Validator (Encoded EscrowState, Encoded EscrowDatum)
escrowDatum datumJust = V.do
  datum <- walk datumJust (field @JustValue)
  let datumBd = getDatum (decode datum)
  walkRaw @EscrowDatum datumBd N.do
    state <- field @EscrowDatumState
    yield (state, Encoded datumBd)

--------------------------------------------------------------------------------
-- Guard predicates -------------------------------------------------------------

-- | The escrow price in lovelace, as a bare integer.
escrowPrice :: Integer
escrowPrice = getLovelace Fixed.escrowPrice

{- | The escrow script's own payment credential, as a raw view for one
'equalsData' comparison.
-}
escrowCredential :: Encoded Credential
escrowCredential = encoded Fixed.scriptCredential

{- | An input spending the escrow script's own credential and carrying exactly
the escrow price. Matching the script's own credential — not merely any script
credential — stops an unrelated script UTxO of the same amount from standing in
for the deposit.
-}
isEscrowInput :: Encoded TxInInfo -> Bool
isEscrowInput i =
  let out = atField @TxInInfoResolved i
   in atField @AddressCredential (atField @TxOutAddress out)
        == escrowCredential
        && lovelaceOf out
        == escrowPrice

-- | The lovelace in an output's 'Value': two raw map lookups, no decode.
lovelaceOf :: Encoded TxOut -> Integer
lovelaceOf o =
  assetAmount (atField @TxOutValue o) (encoded adaSymbol) (encoded adaToken)

{- | Total lovelace paid to a payment credential, summed over the outputs
with one raw walk — no 'Value' union, unlike @valuePaidTo@. Staking parts
are ignored, matching @pubKeyOutputsAt@.
-}
lovelacePaidTo :: Credential -> Encoded (List TxOut) -> Integer
lovelacePaidTo cred outputs =
  let credE = encoded cred
   in foldE
        ( \acc o ->
            if atField @AddressCredential (atField @TxOutAddress o) == credE
              then acc + lovelaceOf o
              else acc
        )
        0
        outputs

--------------------------------------------------------------------------------
-- Other helper functions -------------------------------------------------------

-- | Earliest time in a validity range (finite lower bound, @+1@ if exclusive).
lowerBoundTime :: Encoded POSIXTimeRange -> Integer
lowerBoundTime range =
  lowerTime
    1
    "Lower bound of valid range must be finite"
    (atField @IntervalFrom range)

-- | Latest time in a validity range (finite upper bound, @-1@ if exclusive).
upperBoundTime :: Encoded POSIXTimeRange -> Integer
upperBoundTime range =
  upperTime
    (negate 1)
    "Upper bound of valid range must be finite"
    (atField @IntervalTo range)

-- | The time of a finite lower interval bound, @+@'openAdj' when exclusive.
lowerTime ::
  Integer -> BuiltinString -> Encoded (LowerBound POSIXTime) -> Integer
lowerTime openAdj msg bound =
  let ext = atField @BoundExtended bound
   in if tagOf ext == 1
        then
          let t = getPOSIXTime (decode (atField @FiniteValue ext))
           in if tagOf (atField @BoundClosure bound) == 1
                then t
                else t + openAdj
        else traceError msg

-- | The time of a finite upper interval bound, @+@'openAdj' when exclusive.
upperTime ::
  Integer -> BuiltinString -> Encoded (UpperBound POSIXTime) -> Integer
upperTime openAdj msg bound =
  let ext = atField @BoundExtended bound
   in if tagOf ext == 1
        then
          let t = getPOSIXTime (decode (atField @FiniteValue ext))
           in if tagOf (atField @BoundClosure bound) == 1
                then t
                else t + openAdj
        else traceError msg
