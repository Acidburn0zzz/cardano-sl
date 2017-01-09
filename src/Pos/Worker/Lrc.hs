{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Workers responsible for Leaders and Richmen computation.

module Pos.Worker.Lrc
       ( lrcOnNewSlotWorker
       ) where

import           Control.TimeWarp.Timed   (fork_)
import qualified Data.HashMap.Strict      as HM
import qualified Data.List.NonEmpty       as NE
import           Formatting               (build, sformat, (%))
import           Serokell.Util.Exceptions ()
import           System.Wlog              (logInfo)
import           Universum

import           Pos.Binary.Communication ()
import           Pos.Block.Logic          (applyBlocks, rollbackBlocks, withBlkSemaphore_)
import           Pos.Constants            (k)
import           Pos.Context              (isLeadersComputed, readLeadersEager,
                                           writeLeaders)
import qualified Pos.DB                   as DB
import           Pos.FollowTheSatoshi     (followTheSatoshiM)
import           Pos.Richmen              (allLrcConsumers, findAllRichmenMaybe)
import           Pos.Slotting             (onNewSlot)
import           Pos.Ssc.Class            (SscWorkersClass)
import           Pos.Ssc.Extra            (sscCalculateSeed)
import           Pos.Types                (EpochOrSlot (..), EpochOrSlot (..), HeaderHash,
                                           HeaderHash, LrcConsumer (..), SlotId (..),
                                           SlotId (..), crucialSlot, getEpochOrSlot,
                                           getEpochOrSlot)
import           Pos.WorkMode             (WorkMode)

lrcOnNewSlotWorker :: (SscWorkersClass ssc, WorkMode ssc m) => m ()
lrcOnNewSlotWorker = onNewSlot True $ lrcOnNewSlotImpl allLrcConsumers

lrcOnNewSlotImpl :: WorkMode ssc m => [LrcConsumer m] -> SlotId -> m ()
lrcOnNewSlotImpl consumers slotId@SlotId{..}
    | siSlot < k = do
        expectedRichmenComp <- filterM (flip lcIfNeedCompute slotId) consumers
        needComputeLeaders <- not <$> isLeadersComputed siEpoch
        let needComputeRichmen = not . null $ expectedRichmenComp
        when needComputeRichmen $ logInfo "Need to compute richmen"
        when needComputeLeaders $ logInfo "Need to compute leaders"

        when (needComputeLeaders || needComputeLeaders) $ do
            logInfo $ "LRC computation is starting"
            withBlkSemaphore_ $ lrcDo slotId expectedRichmenComp
            logInfo $ "LRC computation has finished"
    | otherwise = lrcConsumersClear consumers

lrcDo :: WorkMode ssc m
      => SlotId -> [LrcConsumer m] -> HeaderHash ssc -> m (HeaderHash ssc)
lrcDo slotId consumers tip = tip <$ do
    blockUndoList <- DB.loadBlocksFromTipWhile whileMoreOrEq5k
    when (null blockUndoList) $
        panic "No one block hasn't been generated during last k slots"
    let blockUndos = NE.fromList blockUndoList
    rollbackBlocks blockUndos
    richmenComputationDo slotId consumers
    leadersComputationDo slotId
    applyBlocks (NE.reverse blockUndos)
  where
    whileMoreOrEq5k b _ = getEpochOrSlot b > crucial
    crucial = EpochOrSlot $ Right $ crucialSlot slotId

leadersComputationDo :: WorkMode ssc m => SlotId -> m ()
leadersComputationDo SlotId {siEpoch = epochId} = do
    unlessM (isLeadersComputed epochId) $ do
        mbSeed <- sscCalculateSeed epochId
        totalStake <- DB.getTotalFtsStake
        leaders <-
            case mbSeed of
                Left e     -> panic $ sformat ("SSC couldn't compute seed: "%build) e
                Right seed -> DB.iterateByTx (followTheSatoshiM seed totalStake) snd
        writeLeaders (epochId, leaders)
    (epoch, leaders) <- readLeadersEager
    DB.putLeaders (epoch, leaders)

richmenComputationDo :: forall ssc m . WorkMode ssc m
    => SlotId -> [LrcConsumer m] -> m ()
richmenComputationDo slotId consumers = unless (null consumers) $ do
    -- [CSL-93] Use eligibility threshold here
    total <- DB.getTotalFtsStake
    let minThreshold = safeThreshold total (not . lcConsiderDelegated)
    let minThresholdD = safeThreshold total lcConsiderDelegated
    (richmen, richmenD) <- DB.iterateByStake
                               (findAllRichmenMaybe @ssc minThreshold minThresholdD)
                               identity
    let callCallback cons = fork_ $
            if lcConsiderDelegated cons
            then lcComputedCallback cons slotId total
                   (HM.filter (>= lcThreshold cons total) richmenD)
            else lcComputedCallback cons slotId total
                   (HM.filter (>= lcThreshold cons total) richmen)
    mapM_ callCallback consumers
  where
    safeThreshold total f =
        safeMinimum
        $ map (flip lcThreshold total)
        $ filter f consumers
    safeMinimum a = if null a then Nothing else Just $ minimum a

lrcConsumersClear :: WorkMode ssc m => [LrcConsumer m] -> m ()
lrcConsumersClear = mapM_ lcClearCallback
-- dangerous ^, one thread
