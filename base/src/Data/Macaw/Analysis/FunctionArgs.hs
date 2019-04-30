{-|
Copyright        : (c) Galois, Inc 2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>

This performs a whole-program analysis to compute which registers are
needed to evaluate different blocks.  It can be used to compute which
registers are needed for function arguments.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
module Data.Macaw.Analysis.FunctionArgs
  ( functionDemands
  , DemandSet(..)
  , RegSegmentOff
  , RegisterSet
    -- * Callbacks for architecture-specific information
  , ArchDemandInfo(..)
  , ArchTermStmtRegEffects(..)
  , ComputeArchTermStmtEffects
    -- * Utilities
  , stmtDemandedValues
  ) where

import           Control.Lens
import           Control.Monad.State.Strict
import           Data.Foldable as Fold (traverse_)
import qualified Data.Kind as Kind
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe
#if MIN_VERSION_base(4,12,0)
import           Data.Monoid (Ap(Ap, getAp))
#endif

import           Data.Parameterized.Classes
import           Data.Parameterized.Some
import           Data.Parameterized.TraversableF
import           Data.Semigroup ( Semigroup, (<>) )
import           Data.Set (Set)
import qualified Data.Set as Set
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>), (<>))

import           Data.Macaw.CFG
import           Data.Macaw.CFG.DemandSet
import           Data.Macaw.Discovery.State
import           Data.Macaw.Types

#if !MIN_VERSION_base(4,12,0)
newtype Ap f a = Ap { getAp :: f a }

instance (Applicative f, Semigroup a) => Semigroup (Ap f a) where
  Ap x <> Ap y = Ap $ (<>) <$> x <*> y

instance (Applicative f,
#if !MIN_VERSION_base(4,11,0)
  Semigroup a,
#endif
  Monoid a) => Monoid (Ap f a) where
  mempty = Ap $ pure mempty
  mappend = (<>)
#endif

-------------------------------------------------------------------------------

-- The algorithm computes the set of direct deps (i.e., from writes)
-- and then iterates, propagating back via the register deps.  It
-- doesn't compute assignment uses (although it could) mainly to keep
-- memory use down.  We recompute assignment use later in RegisterUse.
--
-- The basic question this analysis answers is: what arguments does a
-- function require, and what results does it produce?
--
-- There are 3 phases
-- 1. Block-local summarization
-- 2. Function-local summarization
-- 3. Global fixpoint calculation.
--
-- The first 2 phases calculate, for each function, the following information:
--
-- A. What registers are required by a function (ignoring function
--    calls)?
--
-- B. Given that result register {rax, rdx, xmm0} is demanded, what
--    extra register arguments are required, and what extra result
--    arguments are required?
--
-- C. Given that function f now requires argument r, what extra
--    arguments are required, and what extra result registers are
--    demanded?

-- | A set of registrs
type RegisterSet (r :: Type -> Kind.Type) = Set (Some r)

-- | A memory segment offset compatible with the architecture registers.
type RegSegmentOff r = MemSegmentOff (RegAddrWidth r)

-- | This stores the registers needed by a specific address
data DemandSet (r :: Type -> Kind.Type) =
    DemandSet { registerDemands       :: !(RegisterSet r)
                -- | This maps a function address to the registers
                -- that it needs.
              , functionResultDemands :: !(Map (RegSegmentOff r) (RegisterSet r))
              }

-- | Create a demand set for specific registers.
registerDemandSet :: RegisterSet r -> DemandSet r
registerDemandSet s = DemandSet { registerDemands = s, functionResultDemands = Map.empty }

deriving instance (ShowF r, MemWidth (RegAddrWidth r)) => Show (DemandSet r)
deriving instance (TestEquality r) => Eq (DemandSet r)
deriving instance (OrdF r) => Ord (DemandSet r)

instance OrdF r => Semigroup (DemandSet r) where
  ds1 <> ds2 =
    DemandSet { registerDemands = registerDemands ds1 <> registerDemands ds2
              , functionResultDemands =
                  Map.unionWith Set.union (functionResultDemands ds1)
                                          (functionResultDemands ds2)
              }

instance OrdF r => Monoid (DemandSet r) where
  mempty = DemandSet { registerDemands = Set.empty
                     , functionResultDemands = Map.empty
                     }
  mappend = (<>)

demandSetDifference :: OrdF r => DemandSet r -> DemandSet r -> DemandSet r
demandSetDifference ds1 ds2 =
  DemandSet { registerDemands = registerDemands ds1 `Set.difference` registerDemands ds2
            , functionResultDemands =
                Map.differenceWith setDiff
                (functionResultDemands ds1)
                (functionResultDemands ds2)
            }
  where
    setDiff s1 s2 =
      let s' = s1 `Set.difference` s2
      in if Set.null s' then Nothing else Just s'

-- | This type is used a key to describe a reason why we demand a particular register.
-- The type r is for a register.
data DemandType r
  -- | This type is for registers that will always be demanded.
  = DemandAlways
  -- | This type is for registers that are demanded if the function at the given address wants
  -- the given register.
  | forall tp. DemandFunctionArg (RegSegmentOff r) (r tp)
    -- | This is a associated with the registers that are demanded if
    -- the given register is needed as a return value.
  | forall tp. DemandFunctionResult (r tp)

instance (MemWidth (RegAddrWidth r), ShowF r) => Show (DemandType r) where
  showsPrec _ DemandAlways  = showString "DemandAlways"
  showsPrec p (DemandFunctionArg a r) = showParen (p >= 10) $
    showString "DemandFunctionArg " . shows a . showChar ' ' . showsF r
  showsPrec p (DemandFunctionResult r) = showParen (p >= 10) $
    showString "DemandFunctionResult " . showsF r

instance TestEquality r => Eq (DemandType r) where
  DemandAlways == DemandAlways = True
  (DemandFunctionArg faddr1 r1) == (DemandFunctionArg faddr2 r2) =
    faddr1 == faddr2 && isJust (testEquality r1 r2)
  (DemandFunctionResult r1) == (DemandFunctionResult r2) =
    isJust (testEquality r1 r2)
  _ == _ = False

instance OrdF r => Ord (DemandType r) where
  DemandAlways `compare` DemandAlways = EQ
  DemandAlways `compare` _  = LT
  _ `compare` DemandAlways  = GT

  (DemandFunctionArg faddr1 r1) `compare` (DemandFunctionArg faddr2 r2)
    | faddr1 == faddr2 = toOrdering (compareF r1 r2)
    | otherwise = faddr1 `compare` faddr2

  (DemandFunctionArg {}) `compare` _ = LT
  _ `compare` (DemandFunctionArg {}) = GT

  (DemandFunctionResult r1) `compare` (DemandFunctionResult r2) =
    toOrdering (compareF r1 r2)

type DemandMap r = Map (DemandType r) (DemandSet r)

demandMapUnion :: OrdF r => DemandMap r -> DemandMap r -> DemandMap r
demandMapUnion = Map.unionWith mappend

type AssignmentCache r ids = Map (Some (AssignId ids)) (RegisterSet r)

type ResultDemandsMap r = Map (Some r) (DemandSet r)

-- | Describes the effects of an architecture-specific statement
data ArchTermStmtRegEffects arch
   = ArchTermStmtRegEffects { termRegDemands :: ![Some (ArchReg arch)]
                              -- ^ Registers demanded by term statement
                            , termRegTransfers :: [Some (ArchReg arch)]
                              -- ^ Registers that are not modified by
                              -- terminal statement.
                            }

-- | Returns information about the registers needed and modified by a terminal statement
--
-- The first argument is the terminal statement.
--
-- The second is the state of registers when it is executed.
type ComputeArchTermStmtEffects arch ids
   = ArchTermStmt arch ids
   -> RegState (ArchReg arch) (Value arch ids)
   -> ArchTermStmtRegEffects arch

-- | Information about the architecture/environment what arguments a
-- function needs.
data ArchDemandInfo arch = ArchDemandInfo
     { -- | Registers used as arguments to the function.
       functionArgRegs :: ![Some (ArchReg arch)]
       -- | Registers returned by a function
     , functionRetRegs :: ![Some (ArchReg arch)]
       -- | Registers considered callee saved by functions
     , calleeSavedRegs :: !(Set (Some (ArchReg arch)))
       -- | Compute the effects of a terminal statement on registers.
     , computeArchTermStmtEffects :: !(forall ids . ComputeArchTermStmtEffects arch ids)
       -- | Information needed to infer what values are demanded by a AssignRhs and Stmt.
     , demandInfoCtx :: !(DemandContext arch)
     }

-- | This is information needed to compute dependencies for a single function.
data FunctionArgsState arch ids = FAS
  { -- | Holds state about the set of registers that a block uses
    -- (required by this block).
    _blockTransfer :: !(Map (ArchSegmentOff arch) (ResultDemandsMap (ArchReg arch)))

  -- | If a demand d is demanded of block address then the block demands S, s.t.
  --   `blockDemandMap ^. at addr ^. at d = Just S1
  , _blockDemandMap    :: !(Map (ArchSegmentOff arch) (DemandMap (ArchReg arch)))

  -- | Maps each global block label to the set of blocks that have intra-procedural
  -- jumps to that block.  Since the function does not change, we omit the global label
  , _blockPreds     :: !(Map (ArchSegmentOff arch) [ArchSegmentOff arch])
  -- | A cache of the assignments and their deps.  The key is not included
  -- in the set of deps (but probably should be).
  , _assignmentCache :: !(AssignmentCache (ArchReg arch) ids)

  -- | The set of blocks that we have already visited.
  , _visitedBlocks  :: !(Set (ArchSegmentOff arch))

  -- | The set of blocks we need to consider (should be disjoint from visitedBlocks)
  , _blockFrontier  :: ![ParsedBlock arch ids]
  , archDemandInfo :: !(ArchDemandInfo arch)
  , computedAddrSet :: !(Set (ArchSegmentOff arch))
    -- ^ Set of addresses that are used in function image computation
    -- Other functions are assumed to require all arguments.
  }

blockTransfer :: Simple Lens (FunctionArgsState arch ids)
                             (Map (ArchSegmentOff arch) (ResultDemandsMap (ArchReg arch)))
blockTransfer = lens _blockTransfer (\s v -> s { _blockTransfer = v })

blockDemandMap :: Simple Lens (FunctionArgsState arch ids)
                    (Map (ArchSegmentOff arch) (DemandMap (ArchReg arch)))
blockDemandMap = lens _blockDemandMap (\s v -> s { _blockDemandMap = v })

blockPreds :: Simple Lens (FunctionArgsState arch ids) (Map (ArchSegmentOff arch) [ArchSegmentOff arch])
blockPreds = lens _blockPreds (\s v -> s { _blockPreds = v })

assignmentCache :: Simple Lens (FunctionArgsState arch ids) (AssignmentCache (ArchReg arch) ids)
assignmentCache = lens _assignmentCache (\s v -> s { _assignmentCache = v })

-- |The set of blocks that we have already visited or added to frontier
visitedBlocks :: Simple Lens (FunctionArgsState arch ids) (Set (ArchSegmentOff arch))
visitedBlocks = lens _visitedBlocks (\s v -> s { _visitedBlocks = v })

blockFrontier :: Simple Lens (FunctionArgsState arch ids) [ParsedBlock arch ids]
blockFrontier = lens _blockFrontier (\s v -> s { _blockFrontier = v })

initFunctionArgsState :: ArchDemandInfo arch
                      -> Set (ArchSegmentOff arch)
                      -> FunctionArgsState arch ids
initFunctionArgsState ainfo addrs =
  FAS { _blockTransfer     = Map.empty
      , _blockDemandMap    = Map.empty
      , _blockPreds        = Map.empty
      , _assignmentCache   = Map.empty
      , _visitedBlocks     = Set.empty
      , _blockFrontier     = []
      , archDemandInfo     = ainfo
      , computedAddrSet    = addrs
      }

-- ----------------------------------------------------------------------------------------

type FunctionArgsM arch ids a = State (FunctionArgsState arch ids) a

-- ----------------------------------------------------------------------------------------
-- Phase one functions

-- | This registers a block in the first phase (block discovery).
addIntraproceduralJumpTarget :: ArchConstraints arch
                             => DiscoveryFunInfo arch ids
                             -> ArchSegmentOff arch
                             -> ArchSegmentOff arch
                             -> FunctionArgsM arch ids ()
addIntraproceduralJumpTarget fun_info src dest = do  -- record the edge
  blockPreds %= Map.insertWith (++) dest [src]
  visited <- use visitedBlocks
  when (Set.notMember dest visited) $ do
    visitedBlocks %= Set.insert dest
    case Map.lookup dest (fun_info^.parsedBlocks) of
      Just dest_reg -> blockFrontier %= (dest_reg:)
      Nothing -> error $ show $
        text "Could not find target block" <+> text (show dest) <$$>
        indent 2 (text "Source:" <$$> pretty src)

withAssignmentCache :: State (AssignmentCache (ArchReg arch) ids)  a -> FunctionArgsM arch ids a
withAssignmentCache m = do
  c <- use assignmentCache
  let (r, c') = runState m c
  seq c' $ assignmentCache .= c'
  pure r

-- | Return the input registers that a value depends on.
valueUses :: (OrdF (ArchReg arch), FoldableFC (ArchFn arch))
          => Value arch ids tp
          -> State (AssignmentCache (ArchReg arch) ids) (RegisterSet (ArchReg arch))
valueUses (AssignedValue (Assignment a rhs)) = do
  mr <- gets $ Map.lookup (Some a)
  case mr of
    Just s -> pure s
    Nothing -> do
      rhs' <- foldrFC (\v mrhs -> Set.union <$> valueUses v <*> mrhs) (pure Set.empty) rhs
      seq rhs' $ modify' $ Map.insert (Some a) rhs'
      pure $ rhs'
valueUses (Initial r) = do
  pure $! Set.singleton (Some r)
valueUses _ = do
  pure $! Set.empty

addBlockDemands :: OrdF (ArchReg arch) => ArchSegmentOff arch -> DemandMap (ArchReg arch) -> FunctionArgsM arch ids ()
addBlockDemands a m =
  blockDemandMap %= Map.insertWith demandMapUnion a m


-- | Given a block and a maping from register to value after the block
-- has executed, this traverses the registers that will be available
-- in future blocks, and records a mapping from those registers to
-- their input dependencies.
recordBlockTransfer :: forall arch ids
                    .  ( OrdF (ArchReg arch)
                       , FoldableFC (ArchFn arch)
                       )
                    => ArchSegmentOff arch
                       -- ^ Address of current block.
                    -> RegState (ArchReg arch) (Value arch ids)
                       -- ^ Map from registers to values.
                    -> [Some (ArchReg arch)]
                       -- ^ List of registers that subsequent blocks may depend on.
                    -> FunctionArgsM arch ids ()
recordBlockTransfer addr s rs = do
  let doReg :: Some (ArchReg arch)
            ->  State (AssignmentCache (ArchReg arch) ids)
                      (Some (ArchReg arch), DemandSet (ArchReg arch))
      doReg (Some r) = do
        rs' <- valueUses (s ^. boundValue r)
        return (Some r, registerDemandSet rs')
  vs <- withAssignmentCache $ traverse doReg rs
  blockTransfer %= Map.insertWith (Map.unionWith mappend) addr (Map.fromListWith mappend vs)

-- | A block requires a value, and so we need to remember which
-- registers are required.
demandValue :: (OrdF (ArchReg arch), FoldableFC (ArchFn arch))
            => ArchSegmentOff arch
            -> Value arch ids tp
            -> FunctionArgsM arch ids ()
demandValue addr v = do
  regs <- withAssignmentCache $ valueUses v
  addBlockDemands addr $ Map.singleton DemandAlways (registerDemandSet regs)

-- -----------------------------------------------------------------------------
-- Entry point


type AddrDemandMap r = Map (RegSegmentOff r) (DemandSet r)

type ArgDemandsMap r = Map (RegSegmentOff r) (Map (Some r) (AddrDemandMap r))

-- PERF: we can calculate the return types as we go (instead of doing
-- so at the end).
calculateGlobalFixpoint :: forall r
                        .  OrdF r
                        => FunctionArgState r
                        -> AddrDemandMap r
calculateGlobalFixpoint s = go (s^.alwaysDemandMap) (s^.alwaysDemandMap)
  where
    argDemandsMap    = s^.funArgMap
    resultDemandsMap = s^.funResMap
    go :: AddrDemandMap r
       -> AddrDemandMap r
       -> AddrDemandMap r
    go acc new
      | Just ((fun, newDemands), rest) <- Map.maxViewWithKey new =
          let (nexts, acc') = backPropagate acc fun newDemands
          in go acc' (Map.unionWith mappend rest nexts)
      | otherwise = acc

    backPropagate :: AddrDemandMap r
                  -> RegSegmentOff r
                  -> DemandSet r
                  -> (AddrDemandMap r, AddrDemandMap r)
    backPropagate acc fun (DemandSet regs rets) =
      -- We need to push rets through the corresponding functions, and
      -- notify all functions which call fun regs.
      let goRet :: RegSegmentOff r -> Set (Some r) -> DemandSet r
          goRet addr retRegs =
            mconcat [ resultDemandsMap ^. ix addr ^. ix r | r <- Set.toList retRegs ]

          retDemands :: AddrDemandMap r
          retDemands = Map.mapWithKey goRet rets

          regsDemands :: AddrDemandMap r
          regsDemands =
            Map.unionsWith mappend [ argDemandsMap ^. ix fun ^. ix r | r <- Set.toList regs ]

          newDemands = Map.unionWith mappend regsDemands retDemands

          -- All this in newDemands but not in acc
          novelDemands = Map.differenceWith diff newDemands acc
      in (novelDemands, Map.unionWith mappend acc novelDemands )

    diff ds1 ds2 =
        let ds' = ds1 `demandSetDifference` ds2 in
        if ds' == mempty then Nothing else Just ds'

-- A function call is the only block type that results in the
-- generation of function call demands, so we split that aspect out
-- (callee saved are handled in summarizeBlock).
summarizeCall :: forall arch ids
              .  ( FoldableFC (ArchFn arch)
                 , RegisterInfo (ArchReg arch)
                 )
              => Memory (ArchAddrWidth arch)
              -> ArchSegmentOff arch
                 -- ^ The label fro the current block.
              -> RegState (ArchReg arch) (Value arch ids)
                 -- ^ The current mapping from registers to values
              -> Bool
                 -- ^ A flag that is set to true for tail calls.
              -> FunctionArgsM arch ids ()
summarizeCall mem addr finalRegs isTailCall = do
  knownAddrs <- gets computedAddrSet
  case valueAsMemAddr (finalRegs^.boundValue ip_reg) of
    Just faddr0
      | Just faddr <- asSegmentOff mem faddr0
      , Set.member faddr knownAddrs -> do
      -- If a subsequent block demands r, then we note that we want r from
      -- function faddr
      -- FIXME: refactor out Some s
      retRegs <- gets $ functionRetRegs . archDemandInfo
      -- singleton for now, but propagating back will introduce more deps.
      let demandSet sr         = DemandSet mempty (Map.singleton faddr (Set.singleton sr))

      if isTailCall then do
        -- tail call, propagate demands for our return regs to the called function
        let propMap = (\(Some r) -> (DemandFunctionResult r, demandSet (Some r))) <$> retRegs
        addBlockDemands addr $ Map.fromList propMap
       else do
        -- Given a return register sr, this indicates that
        let propResult :: Some (ArchReg arch) -> FunctionArgsM arch ids ()
            propResult sr = do
              --
              let srDemandSet = Map.singleton sr (demandSet sr)
              blockTransfer %= Map.insertWith (Map.unionWith mappend) addr srDemandSet
        traverse_ propResult retRegs

      -- If a function wants argument register r, then we note that this
      -- block needs the corresponding state values.  Note that we could
      -- do this for _all_ registers, but this should make the summaries somewhat smaller.

      -- Associate the demand sets for each potential argument register with the registers used
      -- by faddr.
      argRegs <- gets $ functionArgRegs . archDemandInfo
      let regDemandSet (Some r) = registerDemandSet  <$> valueUses (finalRegs^. boundValue r)
      let demandTypes = viewSome (DemandFunctionArg faddr) <$>  argRegs
      demands <- withAssignmentCache $ traverse regDemandSet argRegs
      addBlockDemands addr $ Map.fromList $ zip demandTypes demands
    _ -> do
      -- In the dynamic case, we just assume all arguments (FIXME: results?)
      argRegs <- gets $ functionArgRegs . archDemandInfo

      do let demandedRegs = [Some ip_reg] ++ argRegs
         let regUses (Some r) = valueUses (finalRegs^. boundValue r)
         demands <- withAssignmentCache $ fmap registerDemandSet $ getAp $ foldMap (Ap . regUses) demandedRegs
         addBlockDemands addr $ Map.singleton DemandAlways demands

-- | Return values that must be evaluated to execute side effects.
stmtDemandedValues :: DemandContext arch
                   -> Stmt arch ids
                   -> [Some (Value arch ids)]
stmtDemandedValues ctx stmt = demandConstraints ctx $

  case stmt of
    AssignStmt a
      | hasSideEffects ctx (assignRhs a) -> do
          foldMapFC (\v -> [Some v]) (assignRhs a)
      | otherwise ->
          []
    WriteMem addr _ v -> [Some addr, Some v]
    CondWriteMem cond addr _ v -> [Some cond, Some addr, Some v]
    InstructionStart _ _ -> []
    -- Comment statements have no specific value.
    Comment _ -> []
    ExecArchStmt astmt -> foldMapF (\v -> [Some v]) astmt
    ArchState _addr assn -> foldMapF (\v -> [Some v]) assn

-- | This function figures out what the block requires
-- (i.e., addresses that are stored to, and the value stored), along
-- with a map of how demands by successor blocks map back to
-- assignments and registers.
summarizeBlock :: forall arch ids
               .  ArchConstraints arch
               => Memory (ArchAddrWidth arch)
               -> DiscoveryFunInfo arch ids
               -> ParsedBlock arch ids -- ^ Current block
               -> FunctionArgsM arch ids ()
summarizeBlock mem interpState b = do
  let addr = pblockAddr b
  -- Add this label to block demand map with empty set.
  addBlockDemands addr mempty

  ctx <- gets $ demandInfoCtx . archDemandInfo
  -- Add all values demanded by non-terminal statements in list.
  mapM_ (mapM_ (\(Some v) -> demandValue addr v) . stmtDemandedValues ctx)
        (pblockStmts b)
  -- Add values demanded by terminal statements
  case pblockTermStmt b of
    ParsedCall finalRegs m_ret_addr -> do
      -- Record the demands based on the call, and add edges between
      -- this note and next nodes.
      case m_ret_addr of
        Nothing -> do
          summarizeCall mem addr finalRegs True
        Just ret_addr -> do
          summarizeCall mem addr finalRegs False
          addIntraproceduralJumpTarget interpState addr ret_addr
          callRegs <- gets $ calleeSavedRegs . archDemandInfo
          recordBlockTransfer addr finalRegs ([Some sp_reg] ++ Set.toList callRegs)

    PLTStub regs _ _ -> do
      -- PLT Stubs demand all registers that could be function
      -- arguments, as well as any registers in regs.
      ainfo <- gets archDemandInfo
      let demandedRegs = Set.fromList (functionArgRegs ainfo)
      demands <- withAssignmentCache $ getAp $ foldMapF (Ap . valueUses) regs
      addBlockDemands addr $ Map.singleton DemandAlways $
        registerDemandSet $ demands <> demandedRegs

    ParsedJump procState tgtAddr -> do
      -- record all propagations
      recordBlockTransfer addr procState archRegs
      addIntraproceduralJumpTarget interpState addr tgtAddr

    ParsedBranch nextRegs cond trueAddr falseAddr -> do
      demandValue addr cond
      -- record all propagations
      let notIP (Some r) = isNothing (testEquality r ip_reg)
      recordBlockTransfer addr nextRegs (filter notIP archRegs)
      addIntraproceduralJumpTarget interpState addr trueAddr
      addIntraproceduralJumpTarget interpState addr falseAddr

    ParsedLookupTable finalRegs lookup_idx vec -> do
      demandValue addr lookup_idx
      -- record all propagations
      recordBlockTransfer addr finalRegs archRegs
      traverse_ (addIntraproceduralJumpTarget interpState addr) vec

    ParsedReturn finalRegs -> do
      retRegs <- gets $ functionRetRegs . archDemandInfo
      let demandTypes = viewSome DemandFunctionResult <$> retRegs
      let regDemandSet (Some r) = registerDemandSet  <$> valueUses (finalRegs^.boundValue r)
      demands <- withAssignmentCache $ traverse regDemandSet retRegs
      addBlockDemands addr $ Map.fromList $ zip demandTypes demands

    ParsedArchTermStmt tstmt finalRegs next_addr -> do
       -- Compute effects of terminal statement.
      ainfo <- gets $ archDemandInfo
      let e = computeArchTermStmtEffects ainfo tstmt finalRegs

      -- Demand all registers the terminal statement demands.
      do let regUses (Some r) = valueUses (finalRegs^.boundValue r)
         demands <- withAssignmentCache $ fmap registerDemandSet $ getAp $
           foldMap (Ap . regUses) (termRegDemands e)
         addBlockDemands addr $ Map.singleton DemandAlways demands

      recordBlockTransfer addr finalRegs (termRegTransfers e)
      traverse_ (addIntraproceduralJumpTarget interpState addr) next_addr

    ParsedTranslateError _ -> do
      -- We ignore demands for translate errors.
      pure ()
    ClassifyFailure _ ->
      -- We ignore demands for classify failure.
      pure ()


-- | Explore states until we have reached end of frontier.
summarizeIter :: ArchConstraints arch
              => Memory (ArchAddrWidth arch)
              -> DiscoveryFunInfo arch ids
              -> FunctionArgsM arch ids ()
summarizeIter mem ist = do
  fnFrontier <- use blockFrontier
  case fnFrontier of
    [] ->
      return ()
    b : frontier' -> do
      blockFrontier .= frontier'
      summarizeBlock mem ist b
      summarizeIter mem ist


transferDemands :: OrdF r
                => Map (Some r) (DemandSet r)
                -> DemandSet r
                -> DemandSet r
transferDemands xfer (DemandSet regs funs) =
  -- Using ix here means we ignore any registers we don't know about,
  -- e.g. caller-saved registers after a function call.
  -- FIXME: is this the correct behavior?
  mconcat (DemandSet mempty funs : [ xfer ^. ix r | r <- Set.toList regs ])

calculateOnePred :: (OrdF (ArchReg arch))
                 => DemandMap (ArchReg arch)
                 -> ArchSegmentOff arch
                 -> FunctionArgsM arch ids (ArchSegmentOff arch, DemandMap (ArchReg arch))
calculateOnePred newDemands predAddr = do
  xfer   <- use (blockTransfer . ix predAddr)

  let demands' = transferDemands xfer <$> newDemands

  -- update uses, returning value before this iteration
  seenDemands <- use (blockDemandMap . ix predAddr)
  addBlockDemands predAddr demands'


  let diff :: OrdF r => DemandSet r -> DemandSet r -> Maybe (DemandSet r)
      diff ds1 ds2 | ds' == mempty = Nothing
                   | otherwise = Just ds'
        where ds' = ds1 `demandSetDifference` ds2

  return (predAddr, Map.differenceWith diff demands' seenDemands)


calculateLocalFixpoint :: forall arch ids
                       .  OrdF (ArchReg arch)
                       => Map (ArchSegmentOff arch) (DemandMap (ArchReg arch))
                       -> FunctionArgsM arch ids ()
calculateLocalFixpoint new =
   case Map.maxViewWithKey new of
     Just ((currAddr, newDemands), rest) -> do
       -- propagate backwards any new demands to the predecessors
       preds <- use $ blockPreds . ix currAddr
       nexts <- filter (not . Map.null . snd) <$> mapM (calculateOnePred newDemands) preds
       calculateLocalFixpoint (Map.unionWith demandMapUnion rest
                                  (Map.fromListWith demandMapUnion nexts))
     Nothing -> return ()


data FunctionArgState r = FunctionArgState {
    _funArgMap       :: !(ArgDemandsMap r)
  , _funResMap       :: !(Map (RegSegmentOff r) (ResultDemandsMap r))
  , _alwaysDemandMap :: !(Map (RegSegmentOff r) (DemandSet r))
  }

funArgMap :: Simple Lens (FunctionArgState r) (ArgDemandsMap r)
funArgMap = lens _funArgMap (\s v -> s { _funArgMap = v })

-- | Get the map from function addresses to what results are demanded.
funResMap :: Simple Lens (FunctionArgState r) (Map (RegSegmentOff r) (ResultDemandsMap r))
funResMap = lens _funResMap (\s v -> s { _funResMap = v })

-- | Get the map from function adderesses to what results are demanded.
alwaysDemandMap :: Simple Lens (FunctionArgState r) (Map (RegSegmentOff r)  (DemandSet r))
alwaysDemandMap = lens _alwaysDemandMap (\s v -> s { _alwaysDemandMap = v })

decomposeMap :: OrdF r
             => DemandSet r
             -> RegSegmentOff r
             -> FunctionArgState r
             -> DemandType r
             -> DemandSet r
             -> FunctionArgState r
decomposeMap _ addr acc (DemandFunctionArg f r) v =
  -- FIXME: A bit of an awkward datatype ...
  let m = Map.singleton (Some r) (Map.singleton addr v)
   in acc & funArgMap %~ Map.insertWith (Map.unionWith (Map.unionWith mappend)) f m
decomposeMap _ addr acc (DemandFunctionResult r) v =
  acc & funResMap %~ Map.insertWith (Map.unionWith mappend) addr (Map.singleton (Some r) v)
-- Strip out callee saved registers as well.
decomposeMap ds addr acc DemandAlways v =
  acc & alwaysDemandMap %~ Map.insertWith mappend addr (v `demandSetDifference` ds)

-- This function computes the following 3 pieces of information:
-- 1. Initial function arguments (ignoring function calls)
-- 2. Function arguments to function arguments
-- 3. Function results to function arguments.
doOneFunction :: forall arch ids
              .  ArchConstraints arch
              => ArchDemandInfo arch
              -> Set (ArchSegmentOff arch)
              -> DiscoveryState arch
              -> FunctionArgState (ArchReg arch)
              -> DiscoveryFunInfo arch ids
              -> FunctionArgState (ArchReg arch)
doOneFunction archFns addrs ist0 acc ist = do
  flip evalState (initFunctionArgsState archFns addrs) $ do
    let addr = discoveredFunAddr ist
    -- Run the first phase (block summarization)
    visitedBlocks .= Set.singleton addr

    case Map.lookup addr (ist^.parsedBlocks) of
      Just b -> blockFrontier .= [b]
      Nothing -> error $ "Could not find initial block for " ++ show addr

    summarizeIter (memory ist0) ist
    -- propagate back uses
    new <- use blockDemandMap

    -- debugM DFunctionArgs (">>>>>>>>>>>>>>>>>>>>>>>>" ++ (showHex addr "" ))
    -- debugM' DFunctionArgs (ppMap (text . show) (ppMap (text . show) (text . show)) new)
    -- debugM DFunctionArgs ("------------------------" ++ (showHex addr "" ))
    -- xfer <- use blockTransfer
    -- debugM' DFunctionArgs (ppMap (text . show) (ppMap (text . show) (text . show)) xfer)

    calculateLocalFixpoint new
    -- summary for entry block has what we want.
    -- m <- use (blockDemandMap . ix addr)
    -- debugM DFunctionArgs ("*************************"  ++ (showHex addr "" ))
    -- debugM' DFunctionArgs (ppMap (text . show) (text . show) m)
    -- debugM DFunctionArgs ("<<<<<<<<<<<<<<<<<<<<<<<<<" ++ (showHex addr "" ))

    funDemands <- use (blockDemandMap . ix addr)

    -- A function may demand a callee saved register as it will store
    -- it onto the stack in order to use it later.  This will get
    -- recorded as a use, which is erroneous, so we strip out any
    -- reference to them here.
    callRegs <- gets $ calleeSavedRegs . archDemandInfo
    let calleeDemandSet = registerDemandSet (Set.insert (Some sp_reg) callRegs)

    return (Map.foldlWithKey' (decomposeMap calleeDemandSet addr) acc funDemands)


-- | This analyzes the discovered functions and returns a mapping from each
functionDemands :: forall arch
                .  ArchConstraints arch
                => ArchDemandInfo arch
                -> DiscoveryState arch
                -> Map (ArchSegmentOff arch) (DemandSet (ArchReg arch))
functionDemands archFns info = calculateGlobalFixpoint (foldl f m0 entries)
  where
    entries =  exploredFunctions info

    addrs = Set.fromList $ viewSome discoveredFunAddr <$> entries

    m0 = FunctionArgState Map.empty Map.empty Map.empty

    f mi (Some finfo) = doOneFunction archFns addrs info mi finfo

{-

debugPrintMap :: DiscoveryState X86_64 -> Map (MemSegmentOff 64) FunctionType -> String
debugPrintMap ist m = "Arguments: \n\t" ++ intercalate "\n\t" (Map.elems comb)
  where -- FIXME: ignores those functions we don't have names for.
        comb = Map.intersectionWith doOne (symbolAddrsAsMap (symbolNames ist)) m
        doOne n ft = BSC.unpack n ++ ": " ++ show (pretty ft)
-}
