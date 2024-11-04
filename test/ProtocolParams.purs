module Test.Ctl.ProtocolParams
  ( suite
  ) where

import Prelude

import Aeson (decodeAeson)
import Ctl.Internal.QueryM.Ogmios (OgmiosProtocolParameters)
import Ctl.Internal.Test.TestPlanM (TestPlanM)
import Data.Either (Either, isRight)
import Effect.Aff (Aff)
import Mote (group, test)
import Test.Ctl.Utils as Utils
import Test.Spec.Assertions (shouldSatisfy)

suite :: TestPlanM (Aff Unit) Unit
suite = do
  aeson <- Utils.readAeson
    "./fixtures/test/ogmios/queryLedgerState-protocolParameters-daf48d087ca62fe0a3a655473f0653bc.json"
  group "ProtocolParameters parser" $ do
    test "is able to parse ogmios response fixture" $
      (decodeAeson aeson :: Either _ { result :: OgmiosProtocolParameters })
        `shouldSatisfy`
          isRight
