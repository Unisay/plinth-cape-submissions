{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE Strict #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
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

-- | Revision 2: the plain Data.V3 implementation of the thread-token escrow.
module TwoPartyEscrow (twoPartyEscrowValidatorCode, twoPartyEscrowValidator) where

import PlutusLedgerApi.Data.V3
import PlutusLedgerApi.V1.Data.Value (lovelaceValueOf, valueOf)
import PlutusLedgerApi.V3.Data.Contexts (txSignedBy)
import PlutusTx
import PlutusTx.Builtins (equalsData)
import PlutusTx.Builtins.Internal qualified as BI
import PlutusTx.Data.AssocMap qualified as Map
import PlutusTx.Data.List qualified as List
import PlutusTx.Prelude
import TwoPartyEscrow.Fixture qualified as Escrow

twoPartyEscrowValidatorCode :: CompiledCode (BuiltinData -> BuiltinUnit)
twoPartyEscrowValidatorCode = $$(PlutusTx.compile [||twoPartyEscrowValidator||])

{-# INLINEABLE twoPartyEscrowValidator #-}
twoPartyEscrowValidator :: BuiltinData -> BuiltinUnit
twoPartyEscrowValidator raw =
  let ctx = unsafeFromBuiltinData raw
      txInfo = scriptContextTxInfo ctx
      redeemer :: Integer = unsafeFromBuiltinData (getRedeemer (scriptContextRedeemer ctx))
   in case scriptContextScriptInfo ctx of
        MintingScript policy ->
          if
            | redeemer == 0 -> validateDeposit txInfo policy
            | redeemer == 1 || redeemer == 2 ->
                require "B1" (exactMint txInfo policy (-1)) (\() -> BI.unitval)
            | otherwise -> traceError "X1"
        SpendingScript ownRef datum ->
          if
            | redeemer == 1 -> validateSpend False txInfo ownRef datum
            | redeemer == 2 -> validateSpend True txInfo ownRef datum
            | otherwise -> traceError "X1"
        _ -> traceError "X2"

{-# INLINEABLE require #-}
require :: BuiltinString -> Bool -> (() -> BuiltinUnit) -> BuiltinUnit
require rule condition next = if condition then next () else traceError rule

{-# INLINEABLE validateDeposit #-}
validateDeposit :: TxInfo -> CurrencySymbol -> BuiltinUnit
validateDeposit txInfo policy =
  require "D1" (txSignedBy txInfo Escrow.buyerKeyHash) $ \() ->
    require "D3" (exactMint txInfo policy 1) $ \() ->
      case List.filter (atCredential ownCredential) (txInfoOutputs txInfo) of
        outputs ->
          require "D4" (List.length outputs == 1) $ \() ->
            let output = List.head outputs
             in require "D5" (lovelaceOf output == price) $ \() ->
                  require "D6" (valueOf (txOutValue output) policy Escrow.tokenName == 1) $ \() ->
                    case ivTo (txInfoValidRange txInfo) of
                      UpperBound (Finite (POSIXTime upper)) _ ->
                        require
                          "D7"
                          ( txOutDatum output
                              == OutputDatum (Datum (toBuiltinData (Escrow.EscrowDatum (POSIXTime (upper - 1)))))
                          )
                          (\() -> BI.unitval)
                      _ -> traceError "D2"
  where
    ownCredential = ScriptCredential (ScriptHash (unCurrencySymbol policy))

{-# INLINEABLE validateSpend #-}
validateSpend :: Bool -> TxInfo -> TxOutRef -> Maybe Datum -> BuiltinUnit
validateSpend refund txInfo ownRef datum =
  case List.find (\input -> txInInfoOutRef input == ownRef) inputs of
    Nothing -> traceError "S1"
    Just ownInput ->
      case addressCredential (txOutAddress (txInInfoResolved ownInput)) of
        PubKeyCredential _ -> traceError "S1"
        ownCredential@(ScriptCredential (ScriptHash ownHash)) ->
          require
            "S2"
            ( List.length (List.filter (atCredential ownCredential . txInInfoResolved) inputs)
                == 1
            )
            $ \() ->
              require
                "S3"
                (mintAmount txInfo (CurrencySymbol ownHash) == -1)
                $ \() ->
                  if refund
                    then require "R1" (txSignedBy txInfo Escrow.buyerKeyHash) $ \() ->
                      require "R2" (deadlinePassed datum (txInfoValidRange txInfo)) $ \() ->
                        require "R3" (paidTo Escrow.buyerKeyHash txInfo >= price) (\() -> BI.unitval)
                    else require "A1" (txSignedBy txInfo Escrow.sellerKeyHash) $ \() ->
                      require "A2" (paidTo Escrow.sellerKeyHash txInfo >= price) (\() -> BI.unitval)
  where
    inputs = txInfoInputs txInfo

{-# INLINEABLE exactMint #-}
exactMint :: TxInfo -> CurrencySymbol -> Integer -> Bool
exactMint txInfo policy quantity =
  case Map.lookup policy (mintValueToMap (txInfoMint txInfo)) of
    Nothing -> False
    Just tokens ->
      equalsData
        (toBuiltinData tokens)
        (toBuiltinData (Map.singleton Escrow.tokenName quantity))

{-# INLINEABLE atCredential #-}
atCredential :: Credential -> TxOut -> Bool
atCredential credential output = addressCredential (txOutAddress output) == credential

{-# INLINEABLE lovelaceOf #-}
lovelaceOf :: TxOut -> Integer
lovelaceOf output = getLovelace (lovelaceValueOf (txOutValue output))

{-# INLINEABLE price #-}
price :: Integer
price = getLovelace Escrow.escrowPrice

{-# INLINEABLE paidTo #-}
paidTo :: PubKeyHash -> TxInfo -> Integer
paidTo key txInfo =
  List.foldr
    ( \output total ->
        if atCredential (PubKeyCredential key) output
          then lovelaceOf output + total
          else total
    )
    0
    (txInfoOutputs txInfo)

{-# INLINEABLE deadlinePassed #-}
deadlinePassed :: Maybe Datum -> POSIXTimeRange -> Bool
deadlinePassed datum range =
  case (datum, ivFrom range) of
    (Just (Datum raw), LowerBound (Finite (POSIXTime lower)) _) ->
      let time = getPOSIXTime (Escrow.depositTime (unsafeFromBuiltinData raw))
       in lower > time + getPOSIXTime Escrow.refundTime
    _ -> False

{-# INLINEABLE mintAmount #-}
mintAmount :: TxInfo -> CurrencySymbol -> Integer
mintAmount txInfo policy =
  case Map.lookup policy (mintValueToMap (txInfoMint txInfo)) of
    Nothing -> 0
    Just tokens -> case Map.lookup Escrow.tokenName tokens of
      Nothing -> 0
      Just quantity -> quantity
