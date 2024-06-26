module Ledger.Sim (
  LedgerSim,
  LedgerSimError (..),
  runLedgerSim,
  submitTx,
  incrementSlot,
  getCurrentSlot,
  lookupUTxO,
  utxosAtAddress,
  getsLedgerState,
  getLedgerState,
  asksLedgerCtx,
  askLedgerCtx,
  throwLedgerError,
  genTxId,
  getTxId,
) where

import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Functor (void)
import Data.Map.Strict qualified as M
import Data.Maybe (mapMaybe)

import Codec.Serialise (serialise)
import Crypto.Hash (Blake2b_224 (Blake2b_224), hashWith)

import Control.Monad.Except (Except, MonadError (throwError), runExcept, withExcept)
import Control.Monad.Reader (ReaderT (runReaderT), asks, mapReaderT, withReaderT)
import Control.Monad.State (StateT (runStateT), mapStateT, modify')
import Control.Monad.State.Strict (gets)
import Ledger.Sim.Submission (SubmissionEnv (SubmissionEnv), SubmissionError)
import Ledger.Sim.Submission qualified as Submission
import Ledger.Sim.Types.Config (LedgerConfig (lc'userCtx))
import Ledger.Sim.Types.State (LedgerState (ls'currentTime, ls'userState, ls'utxos))
import PlutusLedgerApi.V2 (
  Address,
  POSIXTime (getPOSIXTime),
  TxId (TxId),
  TxInInfo (TxInInfo),
  TxInfo (txInfoId),
  TxOut (txOutAddress),
  TxOutRef,
 )
import PlutusTx.Builtins qualified as PlutusTx

type LedgerSim ctx st e =
  ReaderT
    (LedgerConfig ctx)
    ( StateT
        (LedgerState st)
        (Except (LedgerSimError e))
    )

data LedgerSimError e
  = LedgerSimError'Submission SubmissionError
  | LedgerSimError'Application e
  deriving stock (Show, Eq)

runLedgerSim :: LedgerConfig ctx -> LedgerState st -> LedgerSim ctx st e a -> Either (LedgerSimError e) a
runLedgerSim ledgerCfg ledgerState =
  fmap fst
    . runExcept
    . flip runStateT ledgerState
    . flip runReaderT ledgerCfg

lookupUTxO :: TxOutRef -> LedgerSim ctx st e (Maybe TxOut)
lookupUTxO ref = M.lookup ref <$> gets ls'utxos

utxosAtAddress :: Address -> LedgerSim ctx st e [TxInInfo]
utxosAtAddress addr =
  mapMaybe
    ( \(ref, txOut) ->
        if txOutAddress txOut == addr
          then Just $ TxInInfo ref txOut
          else Nothing
    )
    . M.assocs
    <$> gets ls'utxos

{- Known shortcomings:
- Tx id must be generated and is not generated by hashing the tx body (how it works on the chain).
  This is because we don't have a real Cardano.Api TxBody available at hand and creating one from PLA would
  require a lot of effort.
  As a stopgap, Tx id is generated from current POSIX time. This may violate the assumptions of any scripts that
  use hashing inside them. ex: script that checks `txId txInfo != blake2b_224 time` where time is some time from validity range.
- See: 'checkTx'
-}
submitTx :: TxInfo -> LedgerSim ctx st e TxId
submitTx txInfo = do
  -- TODO(chfanghr): Do something with ExBudget
  void $
    withReaderT (SubmissionEnv txInfo) $
      mapReaderT
        (mapStateT (withExcept LedgerSimError'Submission))
        Submission.submit

  pure $ txInfoId txInfo

getCurrentSlot :: LedgerSim ctx st e POSIXTime
getCurrentSlot = gets ls'currentTime

-- | Get a specific component of the user state from the ledger, using given projection function.
getsLedgerState :: (st -> a) -> LedgerSim ctx st e a
getsLedgerState f = gets $ f . ls'userState

-- | Get the user state from the ledger.
getLedgerState :: LedgerSim ctx st e st
getLedgerState = getsLedgerState id

-- | Get a specific component of the user state from the ledger, using given projection function.
asksLedgerCtx :: (ctx -> a) -> LedgerSim ctx st e a
asksLedgerCtx f = asks $ f . lc'userCtx

-- | Get the user state from the ledger.
askLedgerCtx :: LedgerSim ctx st e ctx
askLedgerCtx = asksLedgerCtx id

-- | Throw custom application error.
throwLedgerError :: e -> LedgerSim ctx st e a
throwLedgerError = throwError . LedgerSimError'Application

incrementSlot :: LedgerSim ctx st e ()
incrementSlot =
  modify' $ \st -> st {ls'currentTime = ls'currentTime st + 1}

{- | Generate tx id from time. NOTE: This is simply a stopgap measure used in the simulator. In reality,
tx ids are hashes of a transaction body.
-}
genTxId :: POSIXTime -> TxId
genTxId =
  TxId
    . PlutusTx.toBuiltin
    . convert @_ @ByteString
    . hashWith Blake2b_224
    . LBS.toStrict
    . serialise
    . getPOSIXTime

getTxId :: LedgerSim ctx st e TxId
getTxId = gets $ genTxId . ls'currentTime
