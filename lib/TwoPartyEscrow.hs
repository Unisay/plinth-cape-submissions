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

{- Inliner budgets: uncond 28, callsite 16, swept on both axes against
   total_fee_lovelace (plutus 1.71, CAPE's 1.63 evaluator). At callsite 16:

     uncond     total_fee
     default       65 400
     16            65 072
     24            65 387
     26            66 341
     27            64 742
     28–29 ◀       63 818   (default pair: 65 247)
     30            86 808

   The optimum is a 2x2 plateau, uncond 28–29 by callsite 15–16. Callsite 17
   costs 103 359 at uncond 28, so keep callsite below 17 here. 1.67's pair
   (16, 21) costs 105 952 under 1.71. -}
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=28 #-}
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-callsite-growth=16 #-}

{- |
The two-party-escrow validator on the 'Validator' monad and
"Plinth.Decoder.Named" walk regions — the "HTLC.Monadic" recipe.

The escrow parties, price and script address are compile-time fixture
constants, so every comparison against them is one 'equalsData' on raw
bytes: the datum's state is checked by constructor tag alone, payments are
summed by folding the outputs' raw lovelace entries ('foldE' + 'adaOf', a
positional read of the canonical ada-first 'Value') instead of decoding and
unioning whole 'Value's the way @valuePaidTo@ does, and an escrow input is
recognised by its payment
credential equalling the script's own plus raw amount. The only structural
decodes left are the deposit-time integer and the interval bounds.
-}
module TwoPartyEscrow (
  twoPartyEscrowValidatorCode,
  twoPartyEscrowValidator,
) where

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
  OutputDatumDatum,
  ScriptContextRedeemer,
  ScriptContextScriptInfo,
  ScriptContextTxInfo,
  SpendingScriptDatum,
  TxInInfoResolved,
  TxInfoInputs,
  TxInfoOutputs,
  TxInfoSignatories,
  TxInfoValidRange,
  TxOutAddress,
  TxOutDatum,
  TxOutValue,
  adaOf,
 )
import Plinth.Encoded (
  Encoded (Encoded),
  anyE,
  decode,
  encoded,
  findUniqueE,
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
  pattern PubKeyCredential,
 )
import PlutusTx qualified
import PlutusTx.Code (CompiledCode)
import PlutusTx.Data.List (List)
import PlutusTx.Prelude
import TwoPartyEscrow.Fixture qualified as Escrow

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
    anyE (== encoded Escrow.buyerKeyHash) signatories
  let escrowAddress = encoded Escrow.scriptAddr
  let outputs = atField @TxInfoOutputs txInfo
  let isScriptOutput o = atField @TxOutAddress o == escrowAddress
  -- Exactly one script output, in a single pass.
  let onlyOut =
        findUniqueE
          "No script outputs created"
          "Too many script outputs created"
          isScriptOutput
          outputs
  validate "Wrong script output amount" do
    lovelaceOf onlyOut == escrowPrice
  let outDatum = atField @TxOutDatum onlyOut
  validate "Invalid or missing deposit datum" do
    tagOf outDatum == 2 -- inline OutputDatum
  (state, depositTime) <-
    walkRaw @Escrow.Datum
      (getDatum (decode (atField @OutputDatumDatum outDatum)))
      $ fields @(Escrow.EscrowState, Escrow.DepositTime)
  validate "Invalid or missing deposit datum" do
    tagOf state == 0 -- Deposited
  validate "Invalid or missing deposit datum" do
    getPOSIXTime (decode depositTime) == upperBoundTime validRange

{- | Seller accepts: nothing stays at the script, the escrow price reaches
the seller, and a funded escrow input is actually being spent.
-}
validateAccept :: Encoded TxInfo -> Encoded ScriptInfo -> Validator ()
validateAccept txInfo scriptInfo = V.do
  datumJust <- walk scriptInfo (field @SpendingScriptDatum)
  (state, _) <- escrowDatum datumJust
  validate "Accept only valid from Deposited state" do
    tagOf state == 0 -- Deposited
  (inputs, outputs, signatories) <-
    walk txInfo (fields @(TxInfoInputs, TxInfoOutputs, TxInfoSignatories))
  validate "Seller signature missing" do
    anyE (== encoded Escrow.sellerKeyHash) signatories
  validate "No valid escrow deposit found in inputs" do
    anyE isEscrowInput inputs
  -- One fold: sum the lovelace to the seller and reject any output back to the
  -- script's own credential (the own input sits there, so the guard is the
  -- compile-time constant). Payment credential only: a staking part on the same
  -- credential still locks funds here.
  let sellerCred = encoded (PubKeyCredential Escrow.sellerKeyHash)
  let paidToSeller =
        foldE
          ( \acc o ->
              let cred = atField @AddressCredential (atField @TxOutAddress o)
               in if cred == escrowCredential
                    then traceError "Incomplete withdrawal - funds remain in script"
                    else if cred == sellerCred then acc + lovelaceOf o else acc
          )
          0
          outputs
  validate "Incorrect payment to seller" do
    paidToSeller == escrowPrice

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
    anyE (== encoded Escrow.buyerKeyHash) signatories
  depositTime <- walk datumEsc (field @Escrow.DepositTime)
  validate "Refund time not reached" do
    lowerBoundTime validRange
      > getPOSIXTime (decode depositTime)
      + getPOSIXTime Escrow.refundTime
  let inputs = atField @TxInfoInputs txInfo
  validate "No valid escrow deposit found in inputs" do
    anyE isEscrowInput inputs
  validate "Incorrect refund to buyer" do
    lovelacePaidTo
      (PubKeyCredential Escrow.buyerKeyHash)
      (atField @TxInfoOutputs txInfo)
      == escrowPrice

--------------------------------------------------------------------------------
-- Decoding helpers -------------------------------------------------------------

{- | Unwrap the spending datum's @Just@ once: the state field (checked by
'tagOf' at the call sites) plus the datum as an 'Encoded' 'Escrow.Datum'
view, so a branch that later needs another field re-walks it without
re-unwrapping.
Grabbing the time field here as well measures WORSE (+180 fee) — the same
early-grab loss as HTLC's and LinearVesting's region-merge experiments.
-}
escrowDatum ::
  Encoded (Maybe Datum) -> Validator (Encoded Escrow.State, Encoded Escrow.Datum)
escrowDatum datumJust = V.do
  datum <- walk datumJust (field @JustValue)
  let datumBd = getDatum (decode datum)
  walkRaw @Escrow.Datum datumBd N.do
    state <- field @Escrow.EscrowState
    yield (state, Encoded datumBd)

--------------------------------------------------------------------------------
-- Guard predicates -------------------------------------------------------------

-- | The escrow price in lovelace, as a bare integer.
escrowPrice :: Integer
escrowPrice = getLovelace Escrow.escrowPrice

{- | The escrow script's own payment credential, as a raw view for one
'equalsData' comparison.
-}
escrowCredential :: Encoded Credential
escrowCredential = encoded Escrow.scriptCredential

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

{- | The lovelace in an output's 'Value', read positionally ('adaOf'): no
asset-key comparison, since a ledger output's ADA entry is always first.
-}
lovelaceOf :: Encoded TxOut -> Integer
lovelaceOf o = adaOf (atField @TxOutValue o)

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
