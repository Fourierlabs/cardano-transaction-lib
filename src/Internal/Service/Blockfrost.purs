module Ctl.Internal.Service.Blockfrost
  ( BlockfrostServiceM
  , BlockfrostServiceParams
  , BlockfrostCurrentEpoch(BlockfrostCurrentEpoch)
  -- , BlockfrostProtocolParameters(BlockfrostProtocolParameters)
  , runBlockfrostServiceM
  , getCurrentEpoch
  , getProtocolParameters
  ) where

import Prelude

import Aeson (class DecodeAeson, Finite, JsonDecodeError(..), decodeAeson, decodeJsonString, parseJsonStringToAeson, unpackFinite)
import Affjax (Error, Response, URL, defaultRequest, request) as Affjax
import Affjax.RequestBody (RequestBody) as Affjax
import Affjax.RequestHeader (RequestHeader(ContentType, RequestHeader)) as Affjax
import Affjax.ResponseFormat (string) as Affjax.ResponseFormat
import Affjax.StatusCode (StatusCode(StatusCode)) as Affjax
import Control.Alt ((<|>))
import Control.Monad.Except (ExceptT(ExceptT), runExceptT)
import Control.Monad.Reader.Class (ask)
import Control.Monad.Reader.Trans (ReaderT, runReaderT)
import Ctl.Internal.Cardano.Types.Transaction (Costmdls(..))
import Ctl.Internal.Cardano.Types.Value (Coin(..))
import Ctl.Internal.Contract.QueryBackend (BlockfrostBackend)
import Ctl.Internal.QueryM.Ogmios (CoinsPerUtxoUnit(..), CostModelV1, CostModelV2, Epoch(..), ProtocolParameters(..), rationalToSubcoin, convertCostModel)
import Ctl.Internal.QueryM.Ogmios as Ogmios
import Ctl.Internal.ServerConfig (ServerConfig, mkHttpUrl)
import Ctl.Internal.Service.Error (ClientError(ClientHttpError, ClientHttpResponseError, ClientDecodeJsonError), ServiceError(ServiceBlockfrostError))
import Ctl.Internal.Types.Rational (Rational, reduce)
import Ctl.Internal.Types.Scripts (Language(..))
import Data.Bifunctor (lmap)
import Data.BigInt (BigInt)
import Data.BigInt as BigInt
import Data.BigNumber (BigNumber, toFraction)
import Data.BigNumber as BigNumber
import Data.Either (Either(Left, Right), note)
import Data.Generic.Rep (class Generic)
import Data.HTTP.Method (Method(GET, POST))
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.MediaType (MediaType)
import Data.Newtype (class Newtype, unwrap, wrap)
import Data.Number (infinity)
import Data.Show.Generic (genericShow)
import Data.Tuple.Nested ((/\))
import Data.UInt (UInt)
import Effect.Aff (Aff)
import Effect.Aff.Class (liftAff)

--------------------------------------------------------------------------------
-- BlockfrostServiceM
--------------------------------------------------------------------------------

type BlockfrostServiceParams =
  { blockfrostConfig :: ServerConfig
  , blockfrostApiKey :: Maybe String
  }

type BlockfrostServiceM (a :: Type) = ReaderT BlockfrostServiceParams Aff a

runBlockfrostServiceM
  :: forall (a :: Type). BlockfrostBackend -> BlockfrostServiceM a -> Aff a
runBlockfrostServiceM backend = flip runReaderT serviceParams
  where
  serviceParams :: BlockfrostServiceParams
  serviceParams =
    { blockfrostConfig: backend.blockfrostConfig
    , blockfrostApiKey: backend.blockfrostApiKey
    }

--------------------------------------------------------------------------------
-- Making requests to Blockfrost endpoints
--------------------------------------------------------------------------------

data BlockfrostEndpoint
  = GetCurrentEpoch
  | GetProtocolParams

realizeEndpoint :: BlockfrostEndpoint -> Affjax.URL
realizeEndpoint endpoint =
  case endpoint of
    GetCurrentEpoch -> "/epochs/latest"
    GetProtocolParams -> "/epochs/latest/parameters"

blockfrostGetRequest
  :: BlockfrostEndpoint
  -> BlockfrostServiceM (Either Affjax.Error (Affjax.Response String))
blockfrostGetRequest endpoint = ask >>= \params -> liftAff do
  Affjax.request $ Affjax.defaultRequest
    { method = Left GET
    , url = mkHttpUrl params.blockfrostConfig <> realizeEndpoint endpoint
    , responseFormat = Affjax.ResponseFormat.string
    , headers =
        maybe mempty (\apiKey -> [ Affjax.RequestHeader "project_id" apiKey ])
          params.blockfrostApiKey
    }

blockfrostPostRequest
  :: BlockfrostEndpoint
  -> MediaType
  -> Maybe Affjax.RequestBody
  -> BlockfrostServiceM (Either Affjax.Error (Affjax.Response String))
blockfrostPostRequest endpoint mediaType mbContent =
  ask >>= \params -> liftAff do
    Affjax.request $ Affjax.defaultRequest
      { method = Left POST
      , url = mkHttpUrl params.blockfrostConfig <> realizeEndpoint endpoint
      , content = mbContent
      , responseFormat = Affjax.ResponseFormat.string
      , headers =
          [ Affjax.ContentType mediaType ] <>
            maybe mempty
              (\apiKey -> [ Affjax.RequestHeader "project_id" apiKey ])
              params.blockfrostApiKey
      }

--------------------------------------------------------------------------------
-- Blockfrost response handling
--------------------------------------------------------------------------------

handleBlockfrostResponse
  :: forall (result :: Type)
   . DecodeAeson result
  => Either Affjax.Error (Affjax.Response String)
  -> Either ClientError result
handleBlockfrostResponse (Left affjaxError) =
  Left (ClientHttpError affjaxError)
handleBlockfrostResponse (Right { status: Affjax.StatusCode statusCode, body })
  | statusCode < 200 || statusCode > 299 = do
      blockfrostError <-
        body # lmap (ClientDecodeJsonError body)
          <<< (decodeAeson <=< parseJsonStringToAeson)
      Left $ ClientHttpResponseError (wrap statusCode) $
        ServiceBlockfrostError blockfrostError
  | otherwise =
      body # lmap (ClientDecodeJsonError body)
        <<< (decodeAeson <=< parseJsonStringToAeson)

newtype BlockfrostCurrentEpoch = BlockfrostCurrentEpoch { epoch :: BigInt }

derive instance Generic BlockfrostCurrentEpoch _
derive instance Newtype BlockfrostCurrentEpoch _
derive newtype instance DecodeAeson BlockfrostCurrentEpoch

instance Show BlockfrostCurrentEpoch where
  show = genericShow

-- | `Stringed a` decodes an `a` who was encoded as a `String`
newtype Stringed a = Stringed a

derive instance Newtype (Stringed a) _

instance DecodeAeson a => DecodeAeson (Stringed a) where
  decodeAeson = decodeAeson >=> decodeJsonString >=> Stringed >>> pure

type BlockfrostProtocolParametersRaw =
  --{ "epoch" :: BigInt
  { "min_fee_a" :: UInt -- minFeeCoefficient
  , "min_fee_b" :: UInt -- minFeeConstant
  , "max_block_size" :: UInt -- maxBlockBodySize
  , "max_tx_size" :: UInt -- maxTxSize
  , "max_block_header_size" :: UInt -- maxBlockHeaderSize
  , "key_deposit" :: Stringed BigInt -- stakeKeyDeposit
  , "pool_deposit" :: Stringed BigInt -- poolDeposit
  , "e_max" :: BigInt -- poolRetirementEpochBound
  , "n_opt" :: UInt -- desiredNumberOfPools
  , "a0" :: Finite BigNumber -- poolInfluence
  , "rho" :: Finite BigNumber -- monetaryExpansion
  , "tau" :: Finite BigNumber -- treasuryExpansion
  -- Deprecated in Babbage
  -- , "decentralisation_param"
  -- , "extra_entropy"
  , "protocol_major_ver" :: UInt -- protocolVersion.major
  , "protocol_minor_ver" :: UInt -- protocolVersion.minor 
  -- Deprecated in Alonzo
  -- , "min_utxo"
  , "min_pool_cost" :: Stringed BigInt -- minPoolCost
  -- , "nonce" :: String -- No ogmios version
  , "cost_models" ::
      { "PlutusV1" :: { | CostModelV1 }
      , "PlutusV2" :: { | CostModelV2 }
      }
  , "price_mem" :: Finite BigNumber -- prices.memory
  , "price_step" :: Finite BigNumber -- prices.steps
  , "max_tx_ex_mem" :: Stringed BigInt -- maxExecutionUnitsPerTransaction.memory
  , "max_tx_ex_steps" :: Stringed BigInt -- maxExecutionUnitsPerTransaction.steps
  , "max_block_ex_mem" :: Stringed BigInt -- maxExecutionUnitsPerBlock.memory
  , "max_block_ex_steps" :: Stringed BigInt -- maxExecutionUnitsPerBlock.steps
  , "max_val_size" :: Stringed UInt -- maxValueSize
  , "collateral_percent" :: UInt -- collateralPercentage
  , "max_collateral_inputs" :: UInt -- maxCollateralInputs
  , "coins_per_utxo_size" :: Maybe (Stringed BigInt) -- coinsPerUtxoByte
  , "coins_per_utxo_word" :: Maybe (Stringed BigInt) -- coinsPerUtxoWord
  }

bigNumberToRational :: BigNumber -> Maybe Rational
bigNumberToRational bn = do
  let (numerator' /\ denominator') = toFraction bn (BigNumber.fromNumber infinity)
  numerator <- BigInt.fromString numerator'
  denominator <- BigInt.fromString denominator'
  reduce numerator denominator

bigNumberToRational' :: BigNumber -> Either JsonDecodeError Rational
bigNumberToRational' = note (TypeMismatch "Rational") <<< bigNumberToRational

newtype BlockfrostProtocolParameters =
  BlockfrostProtocolParameters ProtocolParameters

instance DecodeAeson BlockfrostProtocolParameters where
  decodeAeson = decodeAeson >=> \(raw :: BlockfrostProtocolParametersRaw) -> do
    poolPledgeInfluence <- bigNumberToRational' $ unpackFinite raw.a0
    monetaryExpansion <- bigNumberToRational' $ unpackFinite raw.rho
    treasuryCut <- bigNumberToRational' $ unpackFinite raw.tau
    prices <- do
      let
        convert bn = do
          rational <- bigNumberToRational $ unpackFinite bn
          rationalToSubcoin $ wrap rational

      memPrice <- note (TypeMismatch "Rational") $ convert raw.price_mem
      stepPrice <- note (TypeMismatch "Rational") $ convert raw.price_step
      pure { memPrice, stepPrice }

    coinsPerUtxoUnit <-
      maybe
        (Left $ AtKey "coinsPerUtxoByte or coinsPerUtxoWord" $ MissingValue)
        pure
        $ (CoinsPerUtxoByte <<< Coin <<< unwrap <$> raw.coins_per_utxo_size) <|>
          (CoinsPerUtxoWord <<< Coin <<< unwrap <$> raw.coins_per_utxo_word)
              
    pure $ BlockfrostProtocolParameters $ ProtocolParameters
      { protocolVersion: raw.protocol_major_ver /\ raw.protocol_minor_ver
      -- The following two parameters were removed from Babbage
      , decentralization: zero
      , extraPraosEntropy: Nothing
      , maxBlockHeaderSize: raw.max_block_header_size
      , maxBlockBodySize: raw.max_block_size
      , maxTxSize: raw.max_tx_size
      , txFeeFixed: raw.min_fee_b
      , txFeePerByte: raw.min_fee_a
      , stakeAddressDeposit: Coin $ unwrap raw.key_deposit
      , stakePoolDeposit: Coin $ unwrap raw.pool_deposit
      , minPoolCost: Coin $ unwrap raw.min_pool_cost
      , poolRetireMaxEpoch: Epoch raw.e_max
      , stakePoolTargetNum: raw.n_opt
      , poolPledgeInfluence
      , monetaryExpansion
      , treasuryCut
      , coinsPerUtxoUnit: coinsPerUtxoUnit
      , costModels: Costmdls $ Map.fromFoldable
          [ PlutusV1 /\ convertCostModel raw.cost_models."PlutusV1"
          , PlutusV2 /\ convertCostModel raw.cost_models."PlutusV2"
          ]
      , prices
      , maxTxExUnits:
        { mem: unwrap raw.max_tx_ex_mem
        , steps: unwrap raw.max_tx_ex_steps
        }
      , maxBlockExUnits:
        { mem: unwrap raw.max_block_ex_mem
        , steps: unwrap raw.max_block_ex_steps
        }
      , maxValueSize: unwrap raw.max_val_size
      , collateralPercent: raw.collateral_percent
      , maxCollateralInputs: raw.max_collateral_inputs
      }

getCurrentEpoch
  :: BlockfrostServiceM (Either ClientError BlockfrostCurrentEpoch)
getCurrentEpoch = blockfrostGetRequest GetCurrentEpoch
  <#> handleBlockfrostResponse

getProtocolParameters
  :: BlockfrostServiceM (Either ClientError Ogmios.ProtocolParameters)
getProtocolParameters = runExceptT do
  BlockfrostProtocolParameters params <- ExceptT $
    blockfrostGetRequest GetProtocolParams <#> handleBlockfrostResponse
  pure params
