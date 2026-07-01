{-# LANGUAGE RebindableSyntax #-}
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
{- Per-module Plinth inliner tuning, re-swept for THIS validator after the
raw single-walk 'SpendingScript' decode (see
Note [Decoding ScriptContext without redundancy]). Sweep over
inline-unconditional-growth × inline-callsite-growth
(scripts/sweep-inline.sh); callsite adds nothing, and inlining is what collapses
the 'Validator' monad (at default the combinators stay closures: size 887, cpu_max
33M, spt 158). uncond=110 is the optimum — the smallest value reaching the peak
plateau:

  uncond   cpu_max     mem_max  spt  size  fee      cpu_units.sum
  ──────   ─────────   ───────  ───  ────  ───────  ─────────────
   90      29 478 832   68 840  203  2796  101 029    285 018 022
  110 ◀    23 025 929   52 292  267  2586   89 350    253 261 808   <- optimum
  160      23 025 929   51 692  270  3199   98 379    252 877 808

110 wins the cost axes (size + fee) and ties 160 on cpu_max; 160 shaves
cpu_sum/mem_max a hair lower and adds +3 spt, but only by spending +613 size /
+9k fee, so 110 stays the optimum. 90 is dominated on every axis.
-}
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=110 #-}

{- |
The HTLC validator, written in @do@-notation on the early-termination
'Validator' monad (see "Plinth.Validator", Note [Zero-cost Validator monad]).
The whole validator lives here; only the generic, reusable DSL is separate.

@RebindableSyntax@ rebinds @do@/@if@/literals module-wide, so the helpers below
use @case@ instead of @if@ and have 'fromString'/'fromInteger' in scope for
literals.

Each 'ScriptContext'/datum/'TxInfo' field is decoded with a single @Constr@ walk,
and a value that is only compared is never decoded — see
Note [Decoding ScriptContext without redundancy].
-}
module HTLC.Monadic (
  htlcValidatorCode,
  htlcValidator,
) where

import Data.String (fromString)
import HTLC (
  HTLCDatum,
  payer,
  recipient,
  secretHash,
  timeout,
  pattern Claim,
  pattern Refund,
 )
import Plinth.Validator (
  Validator (Validator),
  fromInteger,
  runValidator,
  validate,
  (>>),
  (>>=),
 )
import PlutusLedgerApi.Data.V3
import PlutusTx qualified
import PlutusTx.AsData.Internal (wrapTail, wrapUnsafeDataAsConstr)
import PlutusTx.Builtins (equalsData)
import PlutusTx.Builtins.Internal qualified as BI
import PlutusTx.Code (CompiledCode)
import PlutusTx.Data.List (List)
import PlutusTx.Data.List qualified as List
import PlutusTx.Prelude hiding (fromInteger, (>>), (>>=))

--------------------------------------------------------------------------------
-- Validator -------------------------------------------------------------------

htlcValidatorCode :: CompiledCode (BuiltinData -> BuiltinUnit)
htlcValidatorCode = $$(PlutusTx.compile [||htlcValidator||])

htlcValidator :: BuiltinData -> BuiltinUnit
htlcValidator ctxData = runValidator do
  (txInfo, redBd, scriptInfo) <-
    splitScriptContext (unsafeFromBuiltinData ctxData)
  case unsafeFromBuiltinData redBd of
    Claim preimage -> validateClaim txInfo scriptInfo preimage
    Refund -> validateRefund txInfo scriptInfo

validateClaim :: TxInfo -> ScriptInfo -> BuiltinByteString -> Validator ()
validateClaim txInfo scriptInfo preimage = do
  (ownRefBd, htlcDatum) <- splitSpendingScript scriptInfo
  validate "Preimage does not match stored hash" do
    sha2_256 preimage == secretHash htlcDatum
  (validRange, signatories) <- splitTxInfo txInfo
  validate "Missing recipient signature" do
    signedBy (recipient htlcDatum) signatories
  validate "Claim not permitted at or after timeout" do
    beforeTimeout (timeout htlcDatum) validRange
  inputs <- splitTxInfoInputs txInfo
  validate "Double satisfaction" do
    singleOwnInput inputs (unsafeFromBuiltinData ownRefBd)

validateRefund :: TxInfo -> ScriptInfo -> Validator ()
validateRefund txInfo scriptInfo = do
  (ownRefBd, htlcDatum) <- splitSpendingScript scriptInfo
  (validRange, signatories) <- splitTxInfo txInfo
  validate "Missing payer signature" do
    signedBy (payer htlcDatum) signatories
  validate "Refund not permitted until after timeout" do
    afterTimeout (timeout htlcDatum) validRange
  inputs <- splitTxInfoInputs txInfo
  validate "Double satisfaction" do
    singleOwnInput inputs (unsafeFromBuiltinData ownRefBd)

--------------------------------------------------------------------------------
-- Decode-or-abort steps -------------------------------------------------------

{- | Extract @TxInfo@, the raw redeemer 'BuiltinData', and the (lazy)
'ScriptInfo'. The redeemer is left undecoded so tag dispatch runs before the
@SpendingScript@/datum are forced.
-}
splitScriptContext ::
  ScriptContext ->
  -- | Decoded into: (tx info, raw redeemer, script info)
  Validator (TxInfo, BuiltinData, ScriptInfo)
splitScriptContext scriptContext = Validator \k ->
  case scriptContext of
    ScriptContext txInfo (Redeemer redBd) scriptInfo ->
      k (txInfo, redBd, scriptInfo)

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
  * the high-level @unsafeDataAsConstr :: BuiltinData -> (Integer, [BuiltinData])@
    is @fromOpaque (BI.unsafeDataAsConstr d)@, which materialises the args as a
    Haskell @[BuiltinData]@ (a full spine fold) — WORSE than a record pattern.
  * bundling a late-needed value into an early continuation tuple lengthens its
    decode into a re-forceable @delay@ (CEK does not memoise @force (delay …)@),
    so an abort re-runs that prefix TWICE — the "abort doubling".

Per site:

  * 'splitSpendingScript' — ONE raw walk: @BI.snd (BI.unsafeDataAsConstr …)@ keeps
    the args as a 'BuiltinList' (never the Haskell list or the index) and is shared
    between the own out-ref and the inline datum. The out-ref stays raw
    'BuiltinData' — only compared via 'equalsData' — so it is never decoded; the
    datum comes back as 'HTLCDatum' (a free coerce, fields decoded lazily at use).
  * the datum's fields are read in 'validateClaim'/'validateRefund' with LAZY
    per-field selectors on the shared @htlcDatum@ — see the size/abort tradeoff above.
  * 'splitTxInfo' — hand-walks to indices 7,8 of the large 'TxInfo' in one
    pass (via the @asData@ 'wrapTail' marker so the plugin recognises it), kept
    apart from 'splitTxInfoInputs' so a sig/timeout abort never forces the inputs list (a
    tuple would force all its components before the continuation runs).
-}

{- | One raw single walk of the 'SpendingScript' @Constr@, shared between the own
out-ref (index 0) and the inline datum (index 1, unwrapped from its @Just@). The
out-ref stays raw 'BuiltinData' (only ever compared via 'equalsData'); the datum
is returned as 'HTLCDatum' — a free @asData@ coerce, fields decoded lazily by the
caller. See Note [Decoding ScriptContext without redundancy].
-}
splitSpendingScript ::
  -- | Spending 'ScriptInfo'
  ScriptInfo ->
  -- | Decoded into: (raw own out-ref, datum)
  Validator (BuiltinData, HTLCDatum)
splitSpendingScript scriptInfo = Validator \k ->
  let args = BI.snd (BI.unsafeDataAsConstr (toBuiltinData scriptInfo))
      ownRefBd = BI.head args
      datBd = BI.head (BI.snd (BI.unsafeDataAsConstr (BI.head (BI.tail args))))
   in k (ownRefBd, unsafeFromBuiltinData datBd)

{- | The valid range (index 7) and signatories (index 8) of the large 'TxInfo' in
ONE hand-written walk, kept apart from 'splitTxInfoInputs'.
See Note [Decoding ScriptContext without redundancy].
-}
splitTxInfo ::
  TxInfo ->
  -- | Decoded into: (valid range, signatories)
  Validator (POSIXTimeRange, List PubKeyHash)
splitTxInfo txInfo =
  Validator \k ->
    let !args = BI.snd (wrapUnsafeDataAsConstr (toBuiltinData txInfo))
        !rest1 = wrapTail args
        !rest2 = wrapTail rest1
        !rest3 = wrapTail rest2
        !rest4 = wrapTail rest3
        !rest5 = wrapTail rest4
        !rest6 = wrapTail rest5
        !rest7 = wrapTail rest6
        !rest8 = wrapTail rest7
     in k
          ( unsafeFromBuiltinData (BI.head rest7) :: POSIXTimeRange
          , unsafeFromBuiltinData (BI.head rest8) :: List PubKeyHash
          )

-- | List of transaction input infos
splitTxInfoInputs :: TxInfo -> Validator (List TxInInfo)
splitTxInfoInputs txInfo = Validator \k ->
  case txInfo of TxInfo {txInfoInputs} -> k txInfoInputs

--------------------------------------------------------------------------------
-- Guard predicates -----------------------------------------------------------

-- | True iff the address's payment 'PubKeyHash' is among the signatories.
signedBy :: Address -> List PubKeyHash -> Bool
signedBy (Address (PubKeyCredential pkh) _) signatories =
  List.elem pkh signatories
signedBy _ _ = traceError "Expected PubKeyCredential address"

-- | True iff the whole validity range lies strictly before the claim deadline.
beforeTimeout :: POSIXTime -> POSIXTimeRange -> Bool
beforeTimeout (POSIXTime claimDeadline) range =
  case upperBoundTime range of
    POSIXTime mostCurrentTime ->
      claimDeadline > mostCurrentTime

-- | True iff the whole validity range lies strictly after the refund timeout.
afterTimeout :: POSIXTime -> POSIXTimeRange -> Bool
afterTimeout (POSIXTime refundTimeout) range =
  case lowerBoundTime range of
    POSIXTime leastCurrentTime ->
      leastCurrentTime > refundTimeout

-- | True iff exactly one tx input sits at the own input's payment credential.
singleOwnInput :: List TxInInfo -> TxOutRef -> Bool
singleOwnInput inputs ownRef = countOwnScriptInputs inputs ownRef == 1

--------------------------------------------------------------------------------
-- Other helper functions -----------------------------------------------------

-- | Earliest time in a validity range (finite lower bound, @+1@ if exclusive).
lowerBoundTime :: POSIXTimeRange -> POSIXTime
lowerBoundTime (Interval (LowerBound (Finite t) True) _) = t
lowerBoundTime (Interval (LowerBound (Finite (POSIXTime t)) False) _) =
  POSIXTime (t + 1)
lowerBoundTime _ = traceError "Lower bound of valid range must be finite"

-- | Latest time in a validity range (finite upper bound, @-1@ if exclusive).
upperBoundTime :: POSIXTimeRange -> POSIXTime
upperBoundTime (Interval _ (UpperBound (Finite t) True)) = t
upperBoundTime (Interval _ (UpperBound (Finite (POSIXTime t)) False)) =
  POSIXTime (t - 1)
upperBoundTime _ = traceError "Upper bound of valid range must be finite"

-- | Count the transaction inputs at the own input's payment credential.
countOwnScriptInputs :: List TxInInfo -> TxOutRef -> Integer
countOwnScriptInputs inputs ownRef =
  let ownCred = ownInputCredential inputs ownRef
   in List.foldl
        ( \acc
           ( TxInInfo
               { txInInfoResolved =
                 TxOut {txOutAddress = Address {addressCredential = cred}}
               }
             ) ->
              -- @case@, not @if@: under 'RebindableSyntax' @if@ would route
              -- through an 'ifThenElse' that 'PlutusTx.Prelude' does not export.
              case ownCred `equalsData` toBuiltinData cred of
                True -> acc + 1
                False -> acc
        )
        0
        inputs

{- | The payment credential (raw 'BuiltinData') of the input being spent,
located by its 'TxOutRef'.
-}
ownInputCredential :: List TxInInfo -> TxOutRef -> BuiltinData
ownInputCredential inputs ownRef =
  case List.find isOwn inputs of
    Just
      ( TxInInfo
          { txInInfoResolved =
            TxOut {txOutAddress = Address {addressCredential = cred}}
          }
        ) ->
        toBuiltinData cred
    Nothing -> traceError "Own input not found"
  where
    isOwn (TxInInfo {txInInfoOutRef = oref}) = oref == ownRef
