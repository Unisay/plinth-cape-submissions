{-# OPTIONS_GHC -fno-full-laziness #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-spec-constr #-}
{-# OPTIONS_GHC -fno-specialise #-}
{-# OPTIONS_GHC -fno-strictness #-}
{-# OPTIONS_GHC -fno-unbox-small-strict-fields #-}
{-# OPTIONS_GHC -fno-unbox-strict-fields #-}

-- | Parameters and single-field datum for the thread-token escrow.
module TwoPartyEscrow.Fixture (
  -- * Escrow Parameters
  EscrowDatum (..),
  tokenName,
  escrowPrice,
  escrowDeadlineMillis,
  refundTime,

  -- * Buyer Fixture Data
  buyerKeyHash,
  buyerKeyHashBytes,

  -- * Seller Fixture Data
  sellerKeyHash,
  sellerKeyHashBytes,
) where

import PlutusLedgerApi.Data.V3
import PlutusTx (makeIsDataIndexed)
import PlutusTx.Builtins.HasOpaque (stringToBuiltinByteStringHex)
import Prelude

--------------------------------------------------------------------------------
-- Escrow Parameters -----------------------------------------------------------

-- | Fixed escrow price in lovelace (75 ADA)
escrowPrice :: Lovelace
escrowPrice = Lovelace 75000000

-- | Escrow deadline: 30 minutes, in milliseconds like every 'POSIXTime'.
escrowDeadlineMillis :: Integer
escrowDeadlineMillis = 1800000

-- | Refund time in POSIXTime (based on deadline)
refundTime :: POSIXTime
refundTime = POSIXTime escrowDeadlineMillis

--------------------------------------------------------------------------------
-- Buyer Fixture Data ----------------------------------------------------------

-- | Fixed buyer public key hash
buyerKeyHash :: PubKeyHash
buyerKeyHash = PubKeyHash buyerKeyHashBytes

-- | Fixed buyer public key hash as hex-decoded bytes
buyerKeyHashBytes :: BuiltinByteString
buyerKeyHashBytes =
  stringToBuiltinByteStringHex
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

--------------------------------------------------------------------------------
-- Seller Fixture Data ---------------------------------------------------------

-- | Fixed seller public key hash
sellerKeyHash :: PubKeyHash
sellerKeyHash = PubKeyHash sellerKeyHashBytes

-- | Fixed seller public key hash as hex-decoded bytes
sellerKeyHashBytes :: BuiltinByteString
sellerKeyHashBytes =
  stringToBuiltinByteStringHex
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

-- | The protocol's thread-token name (ASCII bytes 657363726f77).
tokenName :: TokenName
tokenName = TokenName "escrow"

-- | The deposit records only its last valid millisecond.
data EscrowDatum = EscrowDatum {depositTime :: POSIXTime}

makeIsDataIndexed ''EscrowDatum [('EscrowDatum, 0)]
