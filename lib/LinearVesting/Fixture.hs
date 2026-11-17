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

-- | Test fixture data for LinearVesting benchmark
module LinearVesting.Fixture where

import Plinth.Decoder.Named.TH (deriveLayoutFor)
import PlutusLedgerApi.Data.V3 hiding (Datum)
import PlutusTx (makeIsDataIndexed)
import PlutusTx.Builtins.HasOpaque (stringToBuiltinByteStringHex)
import Prelude

--------------------------------------------------------------------------------
-- Datum and Redeemer Types ----------------------------------------------------

-- | Vesting parameters stored on-chain as inline datum
data Datum = Datum
  { beneficiary :: Address
  , asset :: (CurrencySymbol, TokenName)
  , totalQty :: Integer
  , periodStart :: Integer
  , periodEnd :: Integer
  , firstUnlockAfter :: Integer
  , installments :: Integer
  }

-- | Redeemer actions for the vesting validator
data VestingRedeemer
  = PartialUnlock
  | FullUnlock

makeIsDataIndexed ''Datum [('Datum, 0)]
makeIsDataIndexed ''VestingRedeemer [('PartialUnlock, 0), ('FullUnlock, 1)]

-- The 'FieldAt' layout of 'Datum', derived from its record fields (index from
-- source order). See "Plinth.Decoder.Named.TH".
$(deriveLayoutFor ''Datum)

--------------------------------------------------------------------------------
-- Beneficiary Fixture Data ----------------------------------------------------

-- | Fixed beneficiary public key hash
beneficiaryKeyHash :: PubKeyHash
beneficiaryKeyHash = PubKeyHash beneficiaryKeyHashBytes

-- | Fixed beneficiary public key hash as hex-decoded bytes
beneficiaryKeyHashBytes :: BuiltinByteString
beneficiaryKeyHashBytes =
  stringToBuiltinByteStringHex
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

--------------------------------------------------------------------------------
-- Vesting Asset ---------------------------------------------------------------

-- | Fixed currency symbol for the vesting token
vestingCurrencySymbol :: CurrencySymbol
vestingCurrencySymbol =
  CurrencySymbol $
    stringToBuiltinByteStringHex
      "dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

-- | Fixed token name for the vesting token ("vest" in hex)
vestingTokenName :: TokenName
vestingTokenName =
  TokenName $
    stringToBuiltinByteStringHex "76657374"

--------------------------------------------------------------------------------
-- Script Address ---------------------------------------------------------------

-- | Standard script address for UPLC validators
scriptAddr :: Address
scriptAddr =
  Address
    ( ScriptCredential
        (ScriptHash "1111111111111111111111111111111111111111111111111111111111")
    )
    Nothing
