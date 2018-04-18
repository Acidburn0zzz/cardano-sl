{-# OPTIONS_GHC -fno-warn-orphans #-}

{- |
   An orphanage for all the non-interesting orphan instances.
-}

module Cardano.Wallet.Orphans where

import           Universum hiding (State)
import           Pos.Core (TxAux(..))

instance Ord TxAux where
    compare = comparing taTx
