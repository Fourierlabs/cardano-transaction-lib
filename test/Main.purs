module Test.Main where

import Prelude
import Data.Const (Const)
import Data.Foldable (sequence_)
import Effect (Effect)
import Effect.Aff (Aff, launchAff_)
import Effect.Aff.Class (liftAff)
import Test.Spec (Spec, describe, it)
import Test.Spec.Runner (runSpec)
import Test.Spec.Reporter (consoleReporter)
import Test.AffInterface as AffInterface
import Test.Parser as ParseTest
import Test.Types.Address as Types.Address
import TestM (TestPlanM)
import Mote (Plan, foldPlan, planT)

-- we use `mote` here so that we can use effects to build up a test tree, which
-- is then interpreted here in a pure context, mainly due to some painful types
-- in Test.Spec which prohibit effects.
main :: Effect Unit
main = do
  launchAff_ $ interpret testPlan

interpret :: TestPlanM Unit -> Aff Unit
interpret spif = do
  plan <- planT $ spif
  let
    spec = go plan
  runSpec [ consoleReporter ] spec
  pure unit
  where
  go :: Plan (Const Void) (Aff Unit) -> Spec Unit
  go =
    foldPlan
      (\{ label, value } -> it label $ liftAff value)
      (\_ -> pure unit)
      (\{ label, value } -> describe label (go $ value))
      sequence_

testPlan :: TestPlanM Unit
testPlan = do
  ParseTest.suite
  AffInterface.suite
  Types.Address.suite
