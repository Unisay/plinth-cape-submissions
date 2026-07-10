{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# OPTIONS_GHC -fno-full-laziness #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-spec-constr #-}
{-# OPTIONS_GHC -fno-specialise #-}
{-# OPTIONS_GHC -fno-strictness #-}
{-# OPTIONS_GHC -fno-unbox-small-strict-fields #-}
{-# OPTIONS_GHC -fno-unbox-strict-fields #-}

-- No explicit export list: 'deriveLayoutFor' generates the field-layout tag
-- types (see "Plinth.Decoder.Named.TH"), whose names cannot be enumerated in
-- an export list here, so the whole module is exported instead.

-- | Test fixture data for TwoPartyEscrow benchmark
module TwoPartyEscrow.Fixture where

import Plinth.Decoder.Named.TH (deriveLayoutFor)
import PlutusLedgerApi.Data.V3 hiding (Datum)
import PlutusTx (makeIsDataIndexed)
import PlutusTx.Builtins.HasOpaque (stringToBuiltinByteStringHex)
import Prelude hiding (State)

--------------------------------------------------------------------------------
-- Escrow Parameters -----------------------------------------------------------

-- | Fixed escrow price in lovelace (75 ADA)
escrowPrice :: Lovelace
escrowPrice = Lovelace 75000000

-- | Escrow deadline in seconds (30 minutes)
escrowDeadlineSeconds :: Integer
escrowDeadlineSeconds = 1800

-- | Refund time in POSIXTime (based on deadline)
refundTime :: POSIXTime
refundTime = POSIXTime escrowDeadlineSeconds

--------------------------------------------------------------------------------
-- Buyer Fixture Data ----------------------------------------------------------

-- | Fixed buyer public key hash
buyerKeyHash :: PubKeyHash
buyerKeyHash = PubKeyHash buyerKeyHashBytes

-- | Fixed buyer public key hash as hex-decoded bytes
buyerKeyHashBytes :: BuiltinByteString
buyerKeyHashBytes =
  stringToBuiltinByteStringHex
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

--------------------------------------------------------------------------------
-- Seller Fixture Data ---------------------------------------------------------

-- | Fixed seller public key hash
sellerKeyHash :: PubKeyHash
sellerKeyHash = PubKeyHash sellerKeyHashBytes

-- | Fixed seller public key hash as hex-decoded bytes
sellerKeyHashBytes :: BuiltinByteString
sellerKeyHashBytes =
  stringToBuiltinByteStringHex
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

--------------------------------------------------------------------------------
-- Script Address ---------------------------------------------------------------

-- | Script hash of the escrow validator.
scriptHash :: ScriptHash
scriptHash =
  ScriptHash "1111111111111111111111111111111111111111111111111111111111"

{- | The escrow script's own payment credential. Escrow-input recognition ties
to this (ignoring any staking part) so an unrelated script UTxO of the same
amount cannot stand in for the deposit.
-}
scriptCredential :: Credential
scriptCredential = ScriptCredential scriptHash

-- | Standard script address for UPLC validators
scriptAddr :: Address
scriptAddr = Address scriptCredential Nothing

--------------------------------------------------------------------------------
-- Datum Types for State Management --------------------------------------------

-- | Escrow state transitions for proper state machine validation
data State
  = -- | Initial state after buyer deposits funds
    Deposited
  | -- | Seller has accepted payment (final state)
    Accepted
  | -- | Buyer has reclaimed funds (final state)
    Refunded

-- | Complete escrow datum containing state and timing information
data Datum = Datum
  { escrowState :: State
  -- ^ Current state of the escrow
  , depositTime :: POSIXTime
  -- ^ When the deposit was made (for deadline calculations)
  }

-- | Initial datum state when escrow is first created
initialEscrowDatum :: POSIXTime -> Datum
initialEscrowDatum depositTime =
  Datum {escrowState = Deposited, depositTime = depositTime}

-- PlutusTx instances for serialization
makeIsDataIndexed
  ''State
  [('Deposited, 0), ('Accepted, 1), ('Refunded, 2)]
makeIsDataIndexed ''Datum [('Datum, 0)]

-- The 'FieldAt' layout of 'Datum', derived from its record fields. See
-- "Plinth.Decoder.Named.TH".
$(deriveLayoutFor ''Datum)
