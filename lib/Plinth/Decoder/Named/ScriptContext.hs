{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
-- The 'FieldAt' class lives in "Plinth.Decoder.Named", the ledger
-- types in @plutus-ledger-api@; the layout instances necessarily live apart
-- from both.
{-# OPTIONS_GHC -Wno-orphans #-}

{- |
Type-level layouts of the (stable) V3 ledger types: an empty field-tag type,
its Constr index and its field type ('FieldAt') per field, tag
names mirroring the types' own record selectors. This is the single place the
Constr indices exist — validator code names fields by tag
(@'field' \@TxInfoValidRange@) and never sees a position (see
Note [Indexed projection] in "Plinth.Decoder.Named").

The wire layout of 'ScriptContext' is fixed by the ledger CDDL per Plutus
version, so the indices are audited once per ledger version, not per
validator.
-}
module Plinth.Decoder.Named.ScriptContext (
  -- * V3 'ScriptContext' field tags
  ScriptContextTxInfo,
  ScriptContextRedeemer,
  ScriptContextScriptInfo,

  -- * V3 'ScriptInfo' field tags (per constructor)
  -- $spendingScript
  SpendingScriptOutRef,
  SpendingScriptDatum,

  -- * Generic constructor-payload tags
  JustValue,
  PairFst,
  PairSnd,
  OutputDatumDatum,

  -- * V3 'TxInfo' field tags
  TxInfoInputs,
  TxInfoReferenceInputs,
  TxInfoOutputs,
  TxInfoFee,
  TxInfoMint,
  TxInfoTxCerts,
  TxInfoWdrl,
  TxInfoValidRange,
  TxInfoSignatories,
  TxInfoRedeemers,
  TxInfoData,
  TxInfoId,
  TxInfoVotes,
  TxInfoProposalProcedures,
  TxInfoCurrentTreasuryAmount,
  TxInfoTreasuryDonation,

  -- * 'TxInInfo' \/ 'TxOut' \/ 'Address' \/ 'Credential' field tags
  TxInInfoOutRef,
  TxInInfoResolved,
  TxOutAddress,
  TxOutValue,
  TxOutDatum,
  AddressCredential,
  PubKeyCredentialHash,

  -- * 'Interval' field tags
  IntervalFrom,
  IntervalTo,
  BoundExtended,
  BoundClosure,
  FiniteValue,

  -- * 'Value' helpers
  assetAmount,
  adaOf,
) where

import Plinth.Decoder.Named (
  FieldAt,
  N0,
  N1,
  N10,
  N11,
  N12,
  N13,
  N14,
  N15,
  N2,
  N3,
  N4,
  N5,
  N6,
  N7,
  N8,
  N9,
 )
import Plinth.Encoded (Encoded (Encoded), decode, lookupE)
import PlutusTx.Builtins.Internal qualified as BI
import PlutusLedgerApi.Data.V3 (
  Address,
  Credential,
  CurrencySymbol,
  Datum,
  DatumHash,
  Extended,
  GovernanceActionId,
  Lovelace,
  LowerBound,
  MintValue,
  OutputDatum,
  POSIXTime,
  POSIXTimeRange,
  ProposalProcedure,
  PubKeyHash,
  Redeemer,
  ScriptContext,
  ScriptInfo,
  ScriptPurpose,
  TokenName,
  TxCert,
  TxId,
  TxInInfo,
  TxInfo,
  TxOut,
  TxOutRef,
  UpperBound,
  Value,
  Vote,
  Voter,
 )
import PlutusTx.Data.AssocMap (Map)
import PlutusTx.Data.List (List)
import PlutusTx.Prelude (Bool, Integer, Maybe)

-- V3 'ScriptContext' -----------------------------------------------------------

data ScriptContextTxInfo

instance FieldAt ScriptContextTxInfo ScriptContext N0 TxInfo

data ScriptContextRedeemer

instance FieldAt ScriptContextRedeemer ScriptContext N1 Redeemer

data ScriptContextScriptInfo

instance FieldAt ScriptContextScriptInfo ScriptContext N2 ScriptInfo

-- V3 'ScriptInfo' ----------------------------------------------------------------

{- $spendingScript
The fields of the @SpendingScript@ constructor (Constr tag 1) of
'ScriptInfo'. A region over 'ScriptInfo' using these tags COMMITS to the
spending constructor without verifying the tag — only walk one when the
script kind is already known (e.g. a spending validator).
-}

data SpendingScriptOutRef

data SpendingScriptDatum

instance FieldAt SpendingScriptOutRef ScriptInfo N0 TxOutRef

instance FieldAt SpendingScriptDatum ScriptInfo N1 (Maybe Datum)

-- Generic constructor payloads ----------------------------------------------------

{- | The payload of a @Just@ node (Constr tag 0 of 'Maybe'). Walking a
@Nothing@ with it is a runtime decode error — commit only when presence is an
invariant (e.g. an inline datum a spending script was invoked with).
-}
data JustValue

instance FieldAt JustValue (Maybe a) N0 a

-- | The first component of an encoded 2-tuple (Constr tag 0 of @(a, b)@).
data PairFst

-- | The second component of an encoded 2-tuple.
data PairSnd

instance FieldAt PairFst (a, b) N0 a

instance FieldAt PairSnd (a, b) N1 b

{- | The payload of an inline @OutputDatum@ (Constr tag 2 of 'OutputDatum').
COMMITS to the constructor without verifying the tag — check 'tagOf' first
when inline presence is not an invariant.
-}
data OutputDatumDatum

instance FieldAt OutputDatumDatum OutputDatum N0 Datum

-- V3 'TxInfo' -------------------------------------------------------------------

data TxInfoInputs

instance FieldAt TxInfoInputs TxInfo N0 (List TxInInfo)

data TxInfoReferenceInputs

instance FieldAt TxInfoReferenceInputs TxInfo N1 (List TxInInfo)

data TxInfoOutputs

instance FieldAt TxInfoOutputs TxInfo N2 (List TxOut)

data TxInfoFee

instance FieldAt TxInfoFee TxInfo N3 Lovelace

data TxInfoMint

instance FieldAt TxInfoMint TxInfo N4 MintValue

data TxInfoTxCerts

instance FieldAt TxInfoTxCerts TxInfo N5 (List TxCert)

data TxInfoWdrl

instance FieldAt TxInfoWdrl TxInfo N6 (Map Credential Lovelace)

data TxInfoValidRange

instance FieldAt TxInfoValidRange TxInfo N7 POSIXTimeRange

data TxInfoSignatories

instance FieldAt TxInfoSignatories TxInfo N8 (List PubKeyHash)

data TxInfoRedeemers

instance FieldAt TxInfoRedeemers TxInfo N9 (Map ScriptPurpose Redeemer)

data TxInfoData

instance FieldAt TxInfoData TxInfo N10 (Map DatumHash Datum)

data TxInfoId

instance FieldAt TxInfoId TxInfo N11 TxId

data TxInfoVotes

instance FieldAt TxInfoVotes TxInfo N12 (Map Voter (Map GovernanceActionId Vote))

data TxInfoProposalProcedures

instance FieldAt TxInfoProposalProcedures TxInfo N13 (List ProposalProcedure)

data TxInfoCurrentTreasuryAmount

instance FieldAt TxInfoCurrentTreasuryAmount TxInfo N14 (Maybe Lovelace)

data TxInfoTreasuryDonation

instance FieldAt TxInfoTreasuryDonation TxInfo N15 (Maybe Lovelace)

-- 'TxInInfo' / 'TxOut' / 'Address' / 'Credential' ---------------------------------

data TxInInfoOutRef

data TxInInfoResolved

data TxOutAddress

data TxOutValue

data TxOutDatum

data AddressCredential

{- | The hash payload of a @PubKeyCredential@ (Constr tag 0 of 'Credential').
COMMITS to the constructor without verifying the tag — check 'tagOf' first
when the credential kind is not an invariant.
-}
data PubKeyCredentialHash

instance FieldAt TxInInfoOutRef TxInInfo N0 TxOutRef

instance FieldAt TxInInfoResolved TxInInfo N1 TxOut

instance FieldAt TxOutAddress TxOut N0 Address

instance FieldAt TxOutValue TxOut N1 Value

instance FieldAt TxOutDatum TxOut N2 OutputDatum

instance FieldAt AddressCredential Address N0 Credential

instance FieldAt PubKeyCredentialHash Credential N0 PubKeyHash

-- 'Interval' ----------------------------------------------------------------------

data IntervalFrom

data IntervalTo

data BoundExtended

data BoundClosure

{- | The payload of a @Finite@ bound (Constr tag 1 of 'Extended'). COMMITS to
the constructor without verifying the tag — check 'tagOf' first.
-}
data FiniteValue

instance FieldAt IntervalFrom POSIXTimeRange N0 (LowerBound POSIXTime)

instance FieldAt IntervalTo POSIXTimeRange N1 (UpperBound POSIXTime)

instance FieldAt BoundExtended (LowerBound a) N0 (Extended a)

instance FieldAt BoundExtended (UpperBound a) N0 (Extended a)

instance FieldAt BoundClosure (LowerBound a) N1 Bool

instance FieldAt BoundClosure (UpperBound a) N1 Bool

instance FieldAt FiniteValue (Extended a) N0 a

-- 'Value' -------------------------------------------------------------------------

{- | The quantity of the given asset in a 'Value': two raw map lookups
('equalsData' on the keys, see 'lookupE'), decoding only the final amount;
@0@ when the asset is absent. That a 'Value' is transparently its nested
@Map CurrencySymbol (Map TokenName Integer)@ is wire-layout knowledge, which
is why this lives with the layout instances.
-}
assetAmount ::
  Encoded Value -> Encoded CurrencySymbol -> Encoded TokenName -> Integer
assetAmount (Encoded v) cs tn =
  lookupE
    cs
    0
    (lookupE tn 0 (decode @Integer))
    (Encoded v :: Encoded (Map CurrencySymbol (Map TokenName Integer)))
{-# INLINE assetAmount #-}

{- | The ADA (lovelace) quantity of a ledger 'Value', read positionally: an
on-chain 'Value' is canonical, so ADA (the empty 'CurrencySymbol') is always
the first outer entry and its empty 'TokenName' the first inner entry. Takes the
first-of-first amount directly, with no key 'equalsData' the way 'assetAmount' does.
Valid only where ADA is always present and first (every ledger 'TxOut'); do NOT
use on a mint 'Value', which may omit ADA.
-}
adaOf :: Encoded Value -> Integer
adaOf (Encoded v) =
  let adaTokens = BI.snd (BI.head (BI.unsafeDataAsMap v))
      amount = BI.snd (BI.head (BI.unsafeDataAsMap adaTokens))
   in decode @Integer (Encoded amount)
{-# INLINE adaOf #-}
