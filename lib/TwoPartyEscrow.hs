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
-- Budgets 16/21 retained from the revision-1 pin; not re-swept.
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=16
  -fplugin-opt Plinth.Plugin:inline-callsite-growth=21 #-}

-- | Revision 2: one thread-token minting policy and spending validator.
module TwoPartyEscrow (
  twoPartyEscrowValidatorCode,
  twoPartyEscrowValidator,
) where

import Plinth.Decoder.Named (atField, field, fields, walk, walkRaw, yield)
import Plinth.Decoder.Named qualified as N
import Plinth.Decoder.Named.ScriptContext
import Plinth.Encoded
import Plinth.Validator (Validator, runValidator, validate)
import Plinth.Validator qualified as V
import PlutusLedgerApi.Data.V3 (
  Credential,
  CurrencySymbol,
  Datum (getDatum),
  Lovelace (getLovelace),
  MintValue,
  POSIXTime (getPOSIXTime),
  Redeemer (getRedeemer),
  ScriptContext,
  ScriptInfo,
  TokenName,
  TxInfo,
  TxOut,
 )
import PlutusTx qualified
import PlutusTx.Builtins.Internal qualified as BI
import PlutusTx.Code (CompiledCode)
import PlutusTx.Data.AssocMap (Map)
import PlutusTx.Data.AssocMap qualified as Map
import PlutusTx.Data.List (List)
import PlutusTx.Prelude
import TwoPartyEscrow.Fixture qualified as Escrow

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
  let purpose = tagOf scriptInfo
  if purpose == 0 || purpose == 1
    then
      let action :: Integer = unsafeFromBuiltinData (getRedeemer (decode redeemer))
       in if purpose == 0
            then
              let policy = atField @MintingScriptPolicy scriptInfo
               in if
                    | action == 0 -> validateDeposit txInfo policy
                    | action == 1 || action == 2 ->
                        validate "B1" (exactMint txInfo policy (-1))
                    | otherwise -> traceError "X1"
            else
              if action == 1 || action == 2
                then validateSpend action txInfo scriptInfo
                else traceError "X1"
    else traceError "X2"

validateDeposit :: Encoded TxInfo -> Encoded CurrencySymbol -> Validator ()
validateDeposit txInfo policy = V.do
  (outputs, validRange, signatories) <-
    walk
      txInfo
      (fields @(TxInfoOutputs, TxInfoValidRange, TxInfoSignatories))
  validate "D1" (anyE (== encoded Escrow.buyerKeyHash) signatories)
  validate "D3" (exactMint txInfo policy 1)
  let ownCredential = scriptCredential policy
  let onlyOut = findUniqueE "D4" "D4" (atCredential ownCredential) outputs
  validate "D5" (lovelaceOf onlyOut == price)
  validate "D6" do
    assetAmount (atField @TxOutValue onlyOut) policy (encoded Escrow.tokenName)
      == 1
  let upper = atField @BoundExtended (atField @IntervalTo validRange)
  if tagOf upper == 1
    then V.do
      validate "D7" do
        let depositTime = getPOSIXTime (decode (atField @FiniteValue upper)) - 1
        atField @TxOutDatum onlyOut
          == Encoded
            (BI.mkConstr 2 (BI.mkCons (escrowDatum depositTime) (BI.mkNilData BI.unitval)))
    else traceError "D2"

validateSpend ::
  Integer -> Encoded TxInfo -> Encoded ScriptInfo -> Validator ()
validateSpend action txInfo scriptInfo = V.do
  (inputs, outputs, mint, validRange, signatories) <-
    walk txInfo N.do
      (inputs, outputs, mint, validRange) <-
        fields @(TxInfoInputs, TxInfoOutputs, TxInfoMint, TxInfoValidRange)
      signatories <- field @TxInfoSignatories
      yield (inputs, outputs, mint, validRange, signatories)
  let ownRef = atField @SpendingScriptOutRef scriptInfo
  let ownInput = findE "S1" ((== ownRef) . atField @TxInInfoOutRef) inputs
  let ownCredential =
        atField @AddressCredential
          (atField @TxOutAddress (atField @TxInInfoResolved ownInput))
  validate "S1" (tagOf ownCredential == 1)
  let Encoded ownHash = atField @ScriptCredentialHash ownCredential
  let policy = Encoded ownHash :: Encoded CurrencySymbol
  validate "S2" do
    countE (atCredential ownCredential . atField @TxInInfoResolved) inputs == 1
  validate "S3" (mintAmount mint policy == -1)
  if action == 1
    then V.do
      validate "A1" (anyE (== encoded Escrow.sellerKeyHash) signatories)
      validate "A2" (paidTo Escrow.sellerKeyHashBytes outputs >= price)
    else V.do
      validate "R1" (anyE (== encoded Escrow.buyerKeyHash) signatories)
      let lower = atField @BoundExtended (atField @IntervalFrom validRange)
      validate "R2" do
        tagOf lower
          == 1
          && getPOSIXTime (decode (atField @FiniteValue lower))
          > spendingDepositTime scriptInfo
          + getPOSIXTime Escrow.refundTime
      validate "R3" (paidTo Escrow.buyerKeyHashBytes outputs >= price)

-- | Both Value and MintValue encode a nested map; mint has no ADA entry.
exactMint :: Encoded TxInfo -> Encoded CurrencySymbol -> Integer -> Bool
exactMint txInfo policy quantity =
  let Encoded mint = atField @TxInfoMint txInfo
   in lookupE
        policy
        False
        (== encoded (Map.singleton Escrow.tokenName quantity))
        (Encoded mint :: Encoded (Map CurrencySymbol (Map TokenName Integer)))

mintAmount :: Encoded MintValue -> Encoded CurrencySymbol -> Integer
mintAmount (Encoded mint) policy =
  assetAmount (Encoded mint) policy (encoded Escrow.tokenName)

scriptCredential :: Encoded CurrencySymbol -> Encoded Credential
scriptCredential (Encoded policy) =
  Encoded (BI.mkConstr 1 (BI.mkCons policy (BI.mkNilData BI.unitval)))

atCredential :: Encoded Credential -> Encoded TxOut -> Bool
atCredential credential output =
  atField @AddressCredential (atField @TxOutAddress output) == credential

lovelaceOf :: Encoded TxOut -> Integer
lovelaceOf output = adaOf (atField @TxOutValue output)

price :: Integer
price = getLovelace Escrow.escrowPrice

paidTo :: BuiltinByteString -> Encoded (List TxOut) -> Integer
paidTo key outputs =
  let credential = Encoded (BI.mkConstr 0 (BI.mkCons (BI.mkB key) (BI.mkNilData BI.unitval)))
   in foldE
        ( \total output ->
            if atCredential credential output
              then total + lovelaceOf output
              else total
        )
        0
        outputs

escrowDatum :: Integer -> BuiltinData
escrowDatum time = BI.mkConstr 0 (BI.mkCons (BI.mkI time) (BI.mkNilData BI.unitval))

-- Deposit establishes the exact datum shape. Refund needs only its time.
spendingDepositTime :: Encoded ScriptInfo -> Integer
spendingDepositTime scriptInfo =
  let datum = atField @JustValue (atField @SpendingScriptDatum scriptInfo)
      raw = getDatum (decode datum)
   in BI.unsafeDataAsI (BI.head (BI.snd (BI.unsafeDataAsConstr raw)))
