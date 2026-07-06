{-# OPTIONS_GHC -fno-full-laziness #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-spec-constr #-}
{-# OPTIONS_GHC -fno-specialise #-}
{-# OPTIONS_GHC -fno-strictness #-}
{-# OPTIONS_GHC -fno-unbox-small-strict-fields #-}
{-# OPTIONS_GHC -fno-unbox-strict-fields #-}

-- | Test fixture data for LinearVesting benchmark
module LinearVesting.Fixture (
  -- * Datum and redeemer types
  VestingDatum (..),
  VestingRedeemer (..),

  -- * Beneficiary Fixture Data
  beneficiaryKeyHash,
  beneficiaryKeyHashBytes,

  -- * Vesting Asset
  vestingCurrencySymbol,
  vestingTokenName,

  -- * Script Address
  scriptAddr,
) where

import PlutusLedgerApi.Data.V3
import PlutusTx (makeIsDataIndexed)
import PlutusTx.Builtins.HasOpaque (stringToBuiltinByteStringHex)
import Prelude

--------------------------------------------------------------------------------
-- Datum and Redeemer Types ----------------------------------------------------

-- | Vesting parameters stored on-chain as inline datum
data VestingDatum = VestingDatum
  { beneficiary :: Address
  , vestingAsset :: (CurrencySymbol, TokenName)
  , totalVestingQty :: Integer
  , vestingPeriodStart :: Integer
  , vestingPeriodEnd :: Integer
  , firstUnlockPossibleAfter :: Integer
  , totalInstallments :: Integer
  }

-- | Redeemer actions for the vesting validator
data VestingRedeemer
  = PartialUnlock
  | FullUnlock

makeIsDataIndexed ''VestingDatum [('VestingDatum, 0)]
makeIsDataIndexed ''VestingRedeemer [('PartialUnlock, 0), ('FullUnlock, 1)]

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
