{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# OPTIONS_GHC -fno-full-laziness #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-spec-constr #-}
{-# OPTIONS_GHC -fno-specialise #-}
{-# OPTIONS_GHC -fno-strictness #-}
{-# OPTIONS_GHC -fno-unbox-small-strict-fields #-}
{-# OPTIONS_GHC -fno-unbox-strict-fields #-}

-- No explicit export list: 'asDataLaidOut' generates the field-layout tag
-- types (see "Plinth.Decoder.Named.TH"), whose names cannot be enumerated in
-- an export list here, so the whole module is exported instead.

-- | Test fixture data for HTLC benchmark
module HTLC.Fixture where

import Plinth.Decoder.Named.TH (asDataLaidOut)
import PlutusLedgerApi.Data.V3 hiding (Datum)
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
asDataLaidOut
  [d|
    data Datum = Datum
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
