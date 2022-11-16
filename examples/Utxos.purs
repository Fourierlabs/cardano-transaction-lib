module Ctl.Examples.Utxos (main, example, contract) where

import Contract.Prelude

import Contract.Address
  ( PaymentPubKeyHash
  , StakePubKeyHash
  , getWalletAddress
  , ownPaymentPubKeyHash
  , ownStakePubKeyHash
  )
import Contract.Config (ConfigParams, testnetNamiConfig)
import Contract.Log (logInfo, logInfo')
import Contract.Monad
  ( Contract
  , launchAff_
  , liftContractM
  , liftedM
  , runContract
  )
import Contract.PlutusData (Datum(Datum), PlutusData(Integer))
import Contract.ScriptLookups as Lookups
import Contract.Scripts (MintingPolicy(PlutusMintingPolicy))
import Contract.Transaction
  ( ScriptRef(NativeScriptRef, PlutusScriptRef)
  , awaitTxConfirmed
  )
import Contract.TxConstraints (DatumPresence(DatumInline, DatumWitness))
import Contract.TxConstraints as Constraints
import Contract.Utxos (utxosAt)
import Contract.Value (Value)
import Contract.Value (lovelaceValueOf, singleton) as Value
import Ctl.Examples.Helpers
  ( buildBalanceSignAndSubmitTx
  , mkCurrencySymbol
  , mkTokenName
  ) as Helpers
import Ctl.Examples.PlutusV2.OneShotMinting (oneShotMintingPolicyScriptV2)
import Data.Array (head) as Array
import Data.BigInt (fromInt) as BigInt
import Data.Log.Tag (tag)
import Data.Map (toUnfoldable) as Map
import Test.QuickCheck.Arbitrary (arbitrary)
import Test.QuickCheck.Gen (randomSampleOne)

main :: Effect Unit
main = example testnetNamiConfig

example :: ConfigParams () -> Effect Unit
example = launchAff_ <<< flip runContract contract

contract :: Contract () Unit
contract = do
  logInfo' "Running Examples.Utxos"
  pkh <- liftedM "Failed to get own PKH" ownPaymentPubKeyHash
  skh <- ownStakePubKeyHash
  address <- liftedM "Failed to get own address" getWalletAddress

  datum <- liftEffect
    $ Datum
    <<< Integer
    <<< BigInt.fromInt
    <$> randomSampleOne arbitrary

  utxos <- utxosAt address
  oref <-
    liftContractM "Utxo set is empty"
      (map fst <<< Array.head <<< Map.toUnfoldable $ utxos)

  oneShotMintingPolicy <- oneShotMintingPolicyScriptV2 oref

  mp0 /\ cs0 <-
    Helpers.mkCurrencySymbol
      (pure $ PlutusMintingPolicy $ oneShotMintingPolicy)
  tn0 <- Helpers.mkTokenName "CTLNFT"

  let plutusScriptRef = PlutusScriptRef oneShotMintingPolicy
  nativeScriptRef <- liftEffect $ NativeScriptRef <$> randomSampleOne arbitrary

  let
    adaValue :: Value
    adaValue = Value.lovelaceValueOf (BigInt.fromInt 2_000_000)

    mintValue :: Value
    mintValue = Value.singleton cs0 tn0 one

    constraints :: Constraints.TxConstraints Void Void
    constraints = mconcat
      [ Constraints.mustMintValue mintValue
      , mustPayWithDatumAndScriptRef pkh skh datum DatumWitness plutusScriptRef
          (mintValue <> adaValue)
      , mustPayWithDatumAndScriptRef pkh skh datum DatumInline nativeScriptRef
          adaValue
      ]

    lookups :: Lookups.ScriptLookups Void
    lookups = Lookups.mintingPolicy mp0 <> Lookups.unspentOutputs utxos

  txHash <- Helpers.buildBalanceSignAndSubmitTx lookups constraints
  awaitTxConfirmed txHash
  logInfo' "Tx submitted successfully!"

  utxos' <- utxosAt address
  logInfo (tag "utxos" $ show utxos') "Utxos after transaction confirmation:"

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

mustPayWithDatumAndScriptRef
  :: forall (i :: Type) (o :: Type)
   . PaymentPubKeyHash
  -> Maybe StakePubKeyHash
  -> Datum
  -> DatumPresence
  -> ScriptRef
  -> Value
  -> Constraints.TxConstraints i o
mustPayWithDatumAndScriptRef pkh Nothing =
  Constraints.mustPayToPubKeyWithDatumAndScriptRef pkh
mustPayWithDatumAndScriptRef pkh (Just skh) =
  Constraints.mustPayToPubKeyAddressWithDatumAndScriptRef pkh skh

