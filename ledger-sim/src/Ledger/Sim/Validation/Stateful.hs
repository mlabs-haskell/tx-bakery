module Ledger.Sim.Validation.Stateful (
  InvalidInputError (..),
  InvalidInputsError (..),
  InvalidReferenceInputsError (..),
  InvalidValidRangeError (..),
  RedeemerKind (..),
  InvalidRedeemerErrorKind (..),
  InvalidRedeemersError (..),
  InvalidTxInfoError (..),
  validateTxInfo,
) where

import Data.Functor.Contravariant (Contravariant (contramap))
import Data.Map qualified as M
import Data.Maybe (mapMaybe)
import Data.Set qualified as S
import Ledger.Sim.Types.LedgerConfig (LedgerConfig (lc'scriptMode, lc'scriptStorage), ScriptMode (ScriptMode'AllowWitness, ScriptMode'MustBeReference))
import Ledger.Sim.Types.LedgerState (LedgerState (ls'currentTime, ls'utxos))
import Ledger.Sim.Validation.Validator (
  Validator,
  contramapAndMapErr,
  validateFoldable,
  validateIf,
  validateListAndAnnotateErrWithIdx,
  validateOptional,
  validateWith,
 )
import PlutusLedgerApi.V1.Interval qualified as IV
import PlutusLedgerApi.V1.Value qualified as Value
import PlutusLedgerApi.V2 (
  Address (addressCredential),
  Credential (ScriptCredential),
  CurrencySymbol (unCurrencySymbol),
  POSIXTime,
  POSIXTimeRange,
  ScriptHash (ScriptHash),
  TxInInfo (
    txInInfoOutRef,
    txInInfoResolved
  ),
  TxInfo (txInfoInputs, txInfoMint, txInfoReferenceInputs, txInfoValidRange),
  TxOut (txOutAddress, txOutReferenceScript),
  TxOutRef,
  Value,
 )

--------------------------------------------------------------------------------

data InvalidInputError
  = InvalidInputError'NotFoundOnLedger TxOutRef
  | InvalidInputError'ReferenceScriptNotAvailable ScriptHash
  deriving stock (Show, Eq)
validateInputExist :: LedgerState st -> Validator InvalidInputError TxInInfo
validateInputExist state =
  contramap txInInfoOutRef $
    validateIf (`M.member` ls'utxos state) InvalidInputError'NotFoundOnLedger

validateInputReferenceScriptAvailable :: LedgerConfig ctx -> Validator InvalidInputError TxInInfo
validateInputReferenceScriptAvailable config =
  contramap (txOutReferenceScript . txInInfoResolved) $
    validateOptional $
      validateIf (`M.member` lc'scriptStorage config) InvalidInputError'ReferenceScriptNotAvailable

--------------------------------------------------------------------------------

data InvalidInputsError = InvalidInputsError'InvalidInput Int InvalidInputError
  deriving stock (Show, Eq)

validateInputs ::
  LedgerConfig cfg -> LedgerState st -> Validator InvalidInputsError [TxInInfo]
validateInputs config state =
  validateListAndAnnotateErrWithIdx InvalidInputsError'InvalidInput $
    mconcat
      [ validateInputExist state
      , validateInputReferenceScriptAvailable config
      ]

--------------------------------------------------------------------------------

data InvalidReferenceInputsError = InvalidReferenceInputsError'InvalidInput Int InvalidInputError
  deriving stock (Show, Eq)

validateReferenceInputs ::
  LedgerState st ->
  Validator
    InvalidReferenceInputsError
    [TxInInfo]
validateReferenceInputs =
  validateListAndAnnotateErrWithIdx InvalidReferenceInputsError'InvalidInput . validateInputExist

--------------------------------------------------------------------------------

newtype InvalidValidRangeError = InvalidValidRangeError'CurrentTimeOutOfRange POSIXTime
  deriving stock (Show, Eq)

validateValidRange :: LedgerState st -> Validator InvalidValidRangeError POSIXTimeRange
validateValidRange state =
  let currentTime = ls'currentTime state
   in validateIf (IV.member currentTime) $ const $ InvalidValidRangeError'CurrentTimeOutOfRange currentTime

--------------------------------------------------------------------------------

data RedeemerKind = RedeemerKind'Spending | RedeemerKind'Minting
  deriving stock (Show, Eq)

data InvalidRedeemerErrorKind
  = InvalidRedeemerErrorKind'UnknownScript
  | InvalidRedeemerErrorKind'MissingReferenceScript
  deriving stock (Show, Eq)

data InvalidRedeemersError = InvalidRedeemersError RedeemerKind InvalidRedeemerErrorKind ScriptHash
  deriving stock (Show, Eq)

validateRedeemers :: LedgerConfig ctx -> [TxInInfo] -> Validator InvalidRedeemersError ([TxInInfo], Value)
validateRedeemers config referenceInputs =
  contramap
    ( \(inputs, mintValue) ->
        let
          validatorHashes =
            mapMaybe
              ( \txInInfo ->
                  let txOut = txInInfoResolved txInInfo
                   in case addressCredential $ txOutAddress txOut of
                        ScriptCredential sh -> Just sh
                        _ -> Nothing
              )
              inputs
          mintingPolicyHashes =
            fmap (ScriptHash . unCurrencySymbol) $
              filter (/= Value.adaSymbol) $
                Value.symbols mintValue
         in
          (validatorHashes, mintingPolicyHashes)
    )
    $ mconcat
      [ contramap fst $ validateScriptHashes RedeemerKind'Spending
      , contramap snd $ validateScriptHashes RedeemerKind'Minting
      ]
  where
    availableReferenceScripts =
      S.fromList $
        mapMaybe (txOutReferenceScript . txInInfoResolved) referenceInputs

    validateScriptHashes :: RedeemerKind -> Validator InvalidRedeemersError [ScriptHash]
    validateScriptHashes k =
      validateFoldable $
        validateIf
          ( liftA2
              (&&)
              (`M.member` lc'scriptStorage config)
              ( case lc'scriptMode config of
                  ScriptMode'AllowWitness -> const True
                  ScriptMode'MustBeReference -> flip S.member availableReferenceScripts
              )
          )
          ( InvalidRedeemersError
              k
              InvalidRedeemerErrorKind'UnknownScript
          )

--------------------------------------------------------------------------------

data InvalidTxInfoError
  = InvalidTxInfoError'InvalidInputs InvalidInputsError
  | InvalidTxInfoError'InvalidReferenceInputs InvalidReferenceInputsError
  | InvalidTxInfoError'InvalidValidRange InvalidValidRangeError
  | InvalidTxInfoError'InvalidRedeemers InvalidRedeemersError
  deriving stock (Show, Eq)

validateTxInfo :: LedgerConfig cfg -> LedgerState st -> Validator InvalidTxInfoError TxInfo
validateTxInfo config state =
  mconcat
    [ contramapAndMapErr txInfoInputs InvalidTxInfoError'InvalidInputs $ validateInputs config state
    , contramapAndMapErr txInfoReferenceInputs InvalidTxInfoError'InvalidReferenceInputs $ validateReferenceInputs state
    , contramapAndMapErr txInfoValidRange InvalidTxInfoError'InvalidValidRange $ validateValidRange state
    , validateWith $
        contramapAndMapErr (liftA2 (,) txInfoInputs txInfoMint) InvalidTxInfoError'InvalidRedeemers
          . validateRedeemers config
          . txInfoReferenceInputs
    ]
