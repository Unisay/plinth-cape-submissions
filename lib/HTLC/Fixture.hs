-- `PlutusTx.AsData.asData` generates `match…` helper bindings that are part
-- of its public API but unused here under the explicit export list.
{-# OPTIONS_GHC -Wno-unused-top-binds #-}
{-# OPTIONS_GHC -fno-full-laziness #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-spec-constr #-}
{-# OPTIONS_GHC -fno-specialise #-}
{-# OPTIONS_GHC -fno-strictness #-}
{-# OPTIONS_GHC -fno-unbox-small-strict-fields #-}
{-# OPTIONS_GHC -fno-unbox-strict-fields #-}

-- | Test fixture data for HTLC benchmark
module HTLC.Fixture (
  -- * Datum and redeemer types
  HTLCDatum,
  HTLCRedeemer,
  payer,
  recipient,
  secretHash,
  timeout,
  pattern HTLCDatum,
  pattern Claim,
  pattern Refund,

  -- * Participants
  payerKeyHash,
  payerKeyHashBytes,
  recipientKeyHash,
  recipientKeyHashBytes,

  -- * HTLC Secret
  correctPreimage,
  wrongPreimage,
  secretHashBytes,
  timeoutPosix,

  -- * Script Address
  scriptAddr,
  scriptHash,
) where

import PlutusLedgerApi.Data.V3
import PlutusTx.AsData (asData)
import PlutusTx.Builtins.HasOpaque (stringToBuiltinByteStringHex)
import Prelude

--------------------------------------------------------------------------------
-- Datum and Redeemer Types ----------------------------------------------------

-- The datum and redeemer types are encoded as 'BuiltinData' via 'asData' rather
-- than ordinary algebraic datatypes. The validator only inspects 3 of 4 datum
-- fields per execution path, so lazy field extraction via the generated pattern
-- synonyms is materially cheaper than the eager 'unsafeFromBuiltinData' decode
-- that 'makeIsDataIndexed' would otherwise produce. See
-- https://plutus.cardano.intersectmbo.org/docs/working-with-scripts/optimizing-scripts-with-asData
asData
  [d|
    data HTLCDatum = HTLCDatum
      { payer :: Address
      , recipient :: Address
      , secretHash :: BuiltinByteString
      , timeout :: POSIXTime
      }
      deriving newtype (FromData, ToData, UnsafeFromData)

    data HTLCRedeemer
      = Claim BuiltinByteString
      | Refund
      deriving newtype (FromData, ToData, UnsafeFromData)
    |]

--------------------------------------------------------------------------------
-- Participants ----------------------------------------------------------------

payerKeyHash :: PubKeyHash
payerKeyHash = PubKeyHash payerKeyHashBytes

payerKeyHashBytes :: BuiltinByteString
payerKeyHashBytes =
  stringToBuiltinByteStringHex
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

recipientKeyHash :: PubKeyHash
recipientKeyHash = PubKeyHash recipientKeyHashBytes

recipientKeyHashBytes :: BuiltinByteString
recipientKeyHashBytes =
  stringToBuiltinByteStringHex
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

--------------------------------------------------------------------------------
-- HTLC Secret -----------------------------------------------------------------

-- | Correct preimage (#deadbeef) whose SHA-256 matches 'secretHashBytes'.
correctPreimage :: BuiltinByteString
correctPreimage = stringToBuiltinByteStringHex "deadbeef"

-- | Wrong preimage (#cafebabe) used for negative tests.
wrongPreimage :: BuiltinByteString
wrongPreimage = stringToBuiltinByteStringHex "cafebabe"

-- | SHA-256 digest of 'correctPreimage'.
secretHashBytes :: BuiltinByteString
secretHashBytes =
  stringToBuiltinByteStringHex
    "5f78c33274e43fa9de5659265c1d917e25c03722dcb0b8d27db8d5feaa813953"

-- | Fixed timeout (POSIX timestamp).
timeoutPosix :: POSIXTime
timeoutPosix = POSIXTime 100

--------------------------------------------------------------------------------
-- Script Address --------------------------------------------------------------

-- | Address of the HTLC validator script
scriptAddr :: Address
scriptAddr = Address (ScriptCredential scriptHash) Nothing

-- | Script hash for the HTLC validator
scriptHash :: ScriptHash
scriptHash = ScriptHash "1111111111111111111111111111111111111111111111111111111111"
