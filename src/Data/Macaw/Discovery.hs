{- |
Copyright        : (c) Galois, Inc 2015-2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>, Simon Winwood <sjw@galois.com>

This provides information about code discovered in binaries.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TemplateHaskell #-}
module Data.Macaw.Discovery
       ( -- * DiscoveryInfo
         State.DiscoveryState
       , State.emptyDiscoveryState
       , State.archInfo
       , State.memory
       , State.funInfo
       , State.exploredFunctions
       , State.symbolNames
       , State.ppDiscoveryStateBlocks
       , State.unexploredFunctions
       , Data.Macaw.Discovery.cfgFromAddrs
       , Data.Macaw.Discovery.markAddrsAsFunction
       , State.CodeAddrReason(..)
       , Data.Macaw.Discovery.analyzeFunction
       , Data.Macaw.Discovery.exploreMemPointers
       , Data.Macaw.Discovery.analyzeDiscoveredFunctions
         -- * DiscoveryFunInfo
       , State.DiscoveryFunInfo
       , State.discoveredFunAddr
       , State.discoveredFunName
       , State.parsedBlocks
         -- * SymbolAddrMap
       , State.SymbolAddrMap
       , State.emptySymbolAddrMap
       , State.symbolAddrMap
       , State.symbolAddrs
       , State.symbolAtAddr
       ) where

import           Control.Lens
import           Control.Monad.ST
import           Control.Monad.State.Strict
import qualified Data.ByteString.Char8 as BSC
import           Data.Foldable
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Parameterized.Classes
import           Data.Parameterized.Nonce
import           Data.Parameterized.Some
import           Data.Parameterized.TraversableF
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Vector as V
import           Data.Word

import           Debug.Trace

import           Data.Macaw.AbsDomain.AbsState
import qualified Data.Macaw.AbsDomain.JumpBounds as Jmp
import           Data.Macaw.AbsDomain.Refine
import qualified Data.Macaw.AbsDomain.StridedInterval as SI
import           Data.Macaw.Architecture.Info
import           Data.Macaw.CFG
import           Data.Macaw.CFG.DemandSet
import           Data.Macaw.CFG.Rewriter
import           Data.Macaw.DebugLogging
import           Data.Macaw.Discovery.AbsEval
import           Data.Macaw.Discovery.State as State
import           Data.Macaw.Memory
import qualified Data.Macaw.Memory.Permissions as Perm
import           Data.Macaw.Types


------------------------------------------------------------------------
-- Utilities

-- | Get code pointers out of a abstract value.
concretizeAbsCodePointers :: MemWidth w
                          => Memory w
                          -> AbsValue w (BVType w)
                          -> [MemSegmentOff w]
concretizeAbsCodePointers mem (FinSet s) =
  [ sa
  | a <- Set.toList s
  , sa <- maybeToList (resolveAbsoluteAddr mem (fromInteger a))
  , segmentFlags (msegSegment sa) `Perm.hasPerm` Perm.execute
  ]
concretizeAbsCodePointers _ (CodePointers s _) =
  [ sa
  | sa <- Set.toList s
  , segmentFlags (msegSegment sa) `Perm.hasPerm` Perm.execute
  ]
  -- FIXME: this is dangerous !!
concretizeAbsCodePointers _mem StridedInterval{} = [] -- FIXME: this case doesn't make sense
  -- debug DCFG ("I think these are code pointers!: " ++ show s) $ []
  -- filter (isCodeAddr mem) $ fromInteger <$> SI.toList s
concretizeAbsCodePointers _mem _ = []

{-
printAddrBacktrace :: Map (ArchMemAddr arch) (FoundAddr arch)
                   -> ArchMemAddr arch
                   -> CodeAddrReason (ArchAddrWidth arch)
                   -> [String]
printAddrBacktrace found_map addr rsn = do
  let pp msg = show addr ++ ": " ++ msg
  let prev prev_addr =
        case Map.lookup prev_addr found_map of
          Just found_info -> printAddrBacktrace found_map prev_addr (foundReason found_info)
          Nothing -> error $ "Unknown reason for address " ++ show prev_addr
  case rsn of
    InWrite src            -> pp ("Written to memory in block at address " ++ show src ++ ".") : prev src
    NextIP src             -> pp ("Target IP for " ++ show src ++ ".") : prev src
    CallTarget src         -> pp ("Target IP of call at " ++ show src ++ ".") : prev src
    InitAddr               -> [pp "Initial entry point."]
    CodePointerInMem src   -> [pp ("Memory address " ++ show src ++ " contained code.")]
    SplitAt src            -> pp ("Split from read of " ++ show src ++ ".") : prev src

-- | Return true if this address was added because of the contents of a global address
-- in memory initially.
--
-- This heuristic is not very accurate, so we avoid printing errors when it leads to
-- issues.
cameFromUnsoundReason :: Map (ArchMemAddr arch) (FoundAddr arch)
                      -> CodeAddrReason (ArchAddrWidth arch)
                      -> Bool
cameFromUnsoundReason found_map rsn = do
  let prev addr =
        case Map.lookup addr found_map of
          Just info -> cameFromUnsoundReason found_map (foundReason info)
          Nothing -> error $ "Unknown reason for address " ++ show addr
  case rsn of
    InWrite{} -> True
    NextIP src  -> prev src
    CallTarget src -> prev src
    SplitAt src -> prev src
    InitAddr -> False
    CodePointerInMem{} -> True
-}

------------------------------------------------------------------------
-- Rewriting block

-- | Apply optimizations to a terminal statement.
rewriteTermStmt :: TermStmt arch src -> Rewriter arch src tgt (TermStmt arch tgt)
rewriteTermStmt tstmt = do
  case tstmt of
    FetchAndExecute regs ->
      FetchAndExecute <$> traverseF rewriteValue regs
    Branch c t f -> do
      tgtCond <- rewriteValue c
      case () of
        _ | Just (NotApp c) <- valueAsApp tgtCond -> do
              Branch c <$> pure f <*> pure t
          | otherwise ->
            Branch tgtCond <$> pure t <*> pure f
    Syscall regs ->
      Syscall <$> traverseF rewriteValue regs
    TranslateError regs msg ->
      TranslateError <$> traverseF rewriteValue regs
                     <*> pure msg

-- | Apply optimizations to code in the block
rewriteBlock :: Block arch src -> Rewriter arch src tgt (Block arch tgt)
rewriteBlock b = do
  (tgtStmts, tgtTermStmt) <- collectRewrittenStmts $ do
    mapM_ rewriteStmt (blockStmts b)
    rewriteTermStmt (blockTerm b)
  -- Return new block
  pure $
    Block { blockAddr  = blockAddr b
          , blockLabel = blockLabel b
          , blockStmts = tgtStmts
          , blockTerm  = tgtTermStmt
          }

------------------------------------------------------------------------
-- Demanded subterm utilities

-- | Add any values needed to compute term statement to demand set.
addTermDemands :: TermStmt arch ids -> DemandComp arch ids ()
addTermDemands t = do
  case t of
    FetchAndExecute regs -> do
      traverseF_ addValueDemands regs
    Branch v _ _ -> do
      addValueDemands v
    Syscall regs -> do
      traverseF_ addValueDemands regs
    TranslateError regs _ -> do
      traverseF_ addValueDemands regs

-- | Add any assignments needed to evaluate statements with side
-- effects and terminal statement to demand set.
addBlockDemands :: Block arch ids -> DemandComp arch ids ()
addBlockDemands b = do
  mapM_ addStmtDemands (blockStmts b)
  addTermDemands (blockTerm b)

-- | Return a block after filtering out statements not needed to compute it.
elimDeadBlockStmts :: AssignIdSet ids -> Block arch ids -> Block arch ids
elimDeadBlockStmts demandSet b =
  b { blockStmts = filter (stmtNeeded demandSet) (blockStmts b)
    }

------------------------------------------------------------------------
-- Memory utilities

-- | Return true if range is entirely contained within a single read only segment.Q
rangeInReadonlySegment :: Memory w
                       -> MemAddr w -- ^ Start of range
                       -> MemWord w -- ^ The size of the range
                       -> Bool
rangeInReadonlySegment mem base size = addrWidthClass (memAddrWidth mem) $
  case asSegmentOff mem base of
    Just mseg -> size <= segmentSize (msegSegment mseg) - msegOffset mseg
                   && Perm.isReadonly (segmentFlags (msegSegment mseg))
    Nothing -> False

------------------------------------------------------------------------
-- DiscoveryState utilities

-- | Mark a escaped code pointer as a function entry.
markAddrAsFunction :: CodeAddrReason (ArchAddrWidth arch)
                      -- ^ Information about why the code address was discovered
                      --
                      -- Used for debugging
                   -> ArchSegmentOff arch
                   -> DiscoveryState arch
                   -> DiscoveryState arch
markAddrAsFunction rsn addr s
  | Map.member addr (s^.funInfo) = s
  | otherwise = s & unexploredFunctions %~ Map.insertWith (\_ old -> old) addr rsn

-- | Mark a list of addresses as function entries with the same reason.
markAddrsAsFunction :: CodeAddrReason (ArchAddrWidth arch)
                    -> [ArchSegmentOff arch]
                    -> DiscoveryState arch
                    -> DiscoveryState arch
markAddrsAsFunction rsn addrs s0 = foldl' (\s a -> markAddrAsFunction rsn a s) s0 addrs


------------------------------------------------------------------------
-- FoundAddr

-- | An address that has been found to be reachable.
data FoundAddr arch
   = FoundAddr { foundReason :: !(CodeAddrReason (ArchAddrWidth arch))
                 -- ^ The reason the address was found to be containing code.
               , foundAbstractState :: !(AbsBlockState (ArchReg arch))
                 -- ^ The abstract state formed from post-states that reach this address.
               }

------------------------------------------------------------------------
-- FunState

-- | The state for the function explroation monad
data FunState arch ids
   = FunState { funNonceGen  :: !(NonceGenerator (ST ids) ids)
              , curFunAddr   :: !(ArchSegmentOff arch)
              , _curFunCtx   :: !(DiscoveryState arch)
                -- ^ Discovery state without this function
              , _curFunBlocks :: !(Map (ArchSegmentOff arch) (ParsedBlock arch ids))
                -- ^ Maps an address to the blocks associated with that address.
              , _foundAddrs :: !(Map (ArchSegmentOff arch) (FoundAddr arch))
                -- ^ Maps found address to the pre-state for that block.
              , _reverseEdges :: !(ReverseEdgeMap arch)
                -- ^ Maps each code address to the list of predecessors that
                -- affected its abstract state.
              , _frontier    :: !(Set (ArchSegmentOff arch))
                -- ^ Addresses to explore next.
              }

-- | Discovery info
curFunCtx :: Simple Lens (FunState arch ids)  (DiscoveryState arch)
curFunCtx = lens _curFunCtx (\s v -> s { _curFunCtx = v })

-- | Information about current function we are working on
curFunBlocks :: Simple Lens (FunState arch ids) (Map (ArchSegmentOff arch) (ParsedBlock arch ids))
curFunBlocks = lens _curFunBlocks (\s v -> s { _curFunBlocks = v })

foundAddrs :: Simple Lens (FunState arch ids) (Map (ArchSegmentOff arch) (FoundAddr arch))
foundAddrs = lens _foundAddrs (\s v -> s { _foundAddrs = v })

type ReverseEdgeMap arch = Map (ArchSegmentOff arch) (Set (ArchSegmentOff arch))

-- | Maps each code address to the list of predecessors that
-- affected its abstract state.
reverseEdges :: Simple Lens (FunState arch ids) (ReverseEdgeMap arch)
reverseEdges = lens _reverseEdges (\s v -> s { _reverseEdges = v })

-- | Set of addresses to explore next.
--
-- This is a map so that we can associate a reason why a code address
-- was added to the frontier.
frontier :: Simple Lens (FunState arch ids) (Set (ArchSegmentOff arch))
frontier = lens _frontier (\s v -> s { _frontier = v })

------------------------------------------------------------------------
-- FunM

-- | A newtype around a function
newtype FunM arch ids a = FunM { unFunM :: StateT (FunState arch ids) (ST ids) a }
  deriving (Functor, Applicative, Monad)

instance MonadState (FunState arch ids) (FunM arch ids) where
  get = FunM $ get
  put s = FunM $ put s

liftST :: ST ids a -> FunM arch ids a
liftST = FunM . lift

------------------------------------------------------------------------
-- Transfer functions

-- | Joins in the new abstract state and returns the locations for
-- which the new state is changed.
mergeIntraJump  :: ArchSegmentOff arch
                  -- ^ Source label that we are jumping from.
                -> AbsBlockState (ArchReg arch)
                   -- ^ Block state after executing instructions.
                -> ArchSegmentOff arch
                   -- ^ Address we are trying to reach.
                -> FunM arch ids ()
mergeIntraJump src ab tgt = do
  info <- uses curFunCtx archInfo
  withArchConstraints info $ do
  when (not (absStackHasReturnAddr ab)) $ do
    debug DCFG ("WARNING: Missing return value in jump from " ++ show src ++ " to\n" ++ show ab) $
      pure ()
  let rsn = NextIP src
  -- Associate a new abstract state with the code region.
  foundMap <- use foundAddrs
  case Map.lookup tgt foundMap of
    -- We have seen this block before, so need to join and see if
    -- the results is changed.
    Just old_info -> do
      case joinD (foundAbstractState old_info) ab of
        Nothing  -> return ()
        Just new -> do
          let new_info = old_info { foundAbstractState = new }
          foundAddrs   %= Map.insert tgt new_info
          reverseEdges %= Map.insertWith Set.union tgt (Set.singleton src)
          frontier %= Set.insert tgt
    -- We haven't seen this block before
    Nothing -> do
      reverseEdges %= Map.insertWith Set.union tgt (Set.singleton src)
      frontier     %= Set.insert tgt
      let found_info = FoundAddr { foundReason = rsn
                                 , foundAbstractState = ab
                                 }
      foundAddrs %= Map.insert tgt found_info

-------------------------------------------------------------------------------
-- Jump table bounds

-- See if expression matches form expected by jump tables
matchJumpTable :: MemWidth (ArchAddrWidth arch)
               => Memory (ArchAddrWidth arch)
               -> BVValue arch ids (ArchAddrWidth arch) -- ^ Memory address that IP is read from.
               -> Maybe (ArchMemAddr arch, BVValue arch ids (ArchAddrWidth arch))
matchJumpTable mem read_addr
    -- Turn the read address into base + offset.
  | Just (BVAdd _ offset base_val) <- valueAsApp read_addr
  , Just base <- asLiteralAddr base_val
    -- Turn the offset into a multiple by an index.
  , Just (BVMul _ (BVValue _ mul) jump_index) <- valueAsApp offset
  , mul == toInteger (addrSize (memAddrWidth mem))
  , Just mseg <- asSegmentOff mem base
  , Perm.isReadonly (segmentFlags (msegSegment mseg)) = do
    Just (base, jump_index)
matchJumpTable _ _ =
    Nothing

data JumpTableBoundsError arch ids
   = CouldNotInterpretAbsValue !(AbsValue (ArchAddrWidth arch) (BVType (ArchAddrWidth arch)))
   | UpperBoundMismatch !(Jmp.UpperBound (BVType (ArchAddrWidth arch))) !Integer
   | CouldNotFindBound String !(ArchAddrValue arch ids)

showJumpTableBoundsError :: ArchConstraints arch => JumpTableBoundsError arch ids -> String
showJumpTableBoundsError err =
  case err of
    CouldNotInterpretAbsValue val ->
      "Index interval is not a stride " ++ show val
    UpperBoundMismatch bnd index_range ->
      "Upper bound mismatch at jumpbounds "
                ++ show bnd
                ++ " domain "
                ++ show index_range
    CouldNotFindBound msg jump_index ->
      show "Could not find  jump table: " ++ msg ++ "\n"
      ++ show (ppValueAssignments jump_index)

-- Returns the index bounds for a jump table of 'Nothing' if this is not a block
-- table.
getJumpTableBounds :: ArchitectureInfo a
                   -> AbsProcessorState (ArchReg a) ids -- ^ Current processor registers.
                   -> ArchMemAddr a -- ^ Base
                   -> BVValue a ids (ArchAddrWidth a) -- ^ Index in jump table
                   -> Either (JumpTableBoundsError a ids) (ArchAddrWord a)
                   -- ^ One past last index in jump table or nothing
getJumpTableBounds info regs base jump_index = withArchConstraints info $
  case transferValue regs jump_index of
    StridedInterval (SI.StridedInterval _ index_base index_range index_stride) -> do
      let mem = absMem regs
      let index_end = index_base + (index_range + 1) * index_stride
      if rangeInReadonlySegment mem base (jumpTableEntrySize info * fromInteger index_end) then
        case Jmp.unsignedUpperBound (regs^.indexBounds) jump_index of
          Right (Jmp.IntegerUpperBound bnd) | bnd == index_range -> Right $! fromInteger index_end
          Right bnd -> Left (UpperBoundMismatch bnd index_range)
          Left  msg -> Left (CouldNotFindBound  msg jump_index)
       else
        error $ "Jump table range is not in readonly memory"
    abs_value -> Left (CouldNotInterpretAbsValue abs_value)


------------------------------------------------------------------------
--

refineProcStateBounds :: ( OrdF (ArchReg arch)
                         , HasRepr (ArchReg arch) TypeRepr
                         )
                      => Value arch ids BoolType
                      -> Bool
                      -> AbsProcessorState (ArchReg arch) ids
                      -> AbsProcessorState (ArchReg arch) ids
refineProcStateBounds v isTrue ps =
  case indexBounds (Jmp.assertPred v isTrue) ps of
    Left{}    -> ps
    Right ps' -> ps'

------------------------------------------------------------------------
-- ParseState

data ParseState arch ids =
  ParseState { _writtenCodeAddrs :: ![ArchSegmentOff arch]
               -- ^ Addresses marked executable that were written to memory.
             , _intraJumpTargets ::
                 ![(ArchSegmentOff arch, AbsBlockState (ArchReg arch))]
             , _newFunctionAddrs :: ![ArchSegmentOff arch]
             }

writtenCodeAddrs :: Simple Lens (ParseState arch ids) [ArchSegmentOff arch]
writtenCodeAddrs = lens _writtenCodeAddrs (\s v -> s { _writtenCodeAddrs = v })

intraJumpTargets :: Simple Lens (ParseState arch ids) [(ArchSegmentOff arch, AbsBlockState (ArchReg arch))]
intraJumpTargets = lens _intraJumpTargets (\s v -> s { _intraJumpTargets = v })

newFunctionAddrs :: Simple Lens (ParseState arch ids) [ArchSegmentOff arch]
newFunctionAddrs = lens _newFunctionAddrs (\s v -> s { _newFunctionAddrs = v })


-- | Mark addresses written to memory that point to code as function entry points.
recordWriteStmt :: ArchitectureInfo arch
                -> Memory (ArchAddrWidth arch)
                -> AbsProcessorState (ArchReg arch) ids
                -> Stmt arch ids
                -> State (ParseState arch ids) ()
recordWriteStmt arch_info mem regs stmt = do
  case stmt of
    WriteMem _addr repr v
      | Just Refl <- testEquality repr (addrMemRepr arch_info) -> do
          withArchConstraints arch_info $ do
          let addrs = concretizeAbsCodePointers mem (transferValue regs v)
          writtenCodeAddrs %= (addrs ++)
    _ -> return ()

-- | Attempt to identify the write to a stack return address, returning
-- instructions prior to that write and return  values.
--
-- This can also return Nothing if the call is not supported.
identifyCall :: ( RegConstraint (ArchReg a)
                , MemWidth (ArchAddrWidth a)
                )
             => Memory (ArchAddrWidth a)
             -> [Stmt a ids]
             -> RegState (ArchReg a) (Value a ids)
             -> Maybe (Seq (Stmt a ids), ArchSegmentOff a)
identifyCall mem stmts0 s = go (Seq.fromList stmts0) Seq.empty
  where -- Get value of stack pointer
        next_sp = s^.boundValue sp_reg
        -- Recurse on statements.
        go stmts after =
          case Seq.viewr stmts of
            Seq.EmptyR -> Nothing
            prev Seq.:> stmt
              -- Check for a call statement by determining if the last statement
              -- writes an executable address to the stack pointer.
              | WriteMem a _repr val <- stmt
              , Just _ <- testEquality a next_sp
                -- Check this is the right length.
              , Just Refl <- testEquality (typeRepr next_sp) (typeRepr val)
                -- Check if value is a valid literal address
              , Just val_a <- asLiteralAddr val
                -- Check if segment of address is marked as executable.
              , Just ret_addr <- asSegmentOff mem val_a
              , segmentFlags (msegSegment ret_addr) `Perm.hasPerm` Perm.execute ->
                Just (prev Seq.>< after, ret_addr)
                -- Stop if we hit any architecture specific instructions prior to
                -- identifying return address since they may have side effects.
              | ExecArchStmt _ <- stmt -> Nothing
                -- Otherwise skip over this instruction.
              | otherwise -> go prev (stmt Seq.<| after)

------------------------------------------------------------------------
-- ParseContext

data ParseContext arch ids = ParseContext { pctxMemory   :: !(Memory (ArchAddrWidth arch))
                                          , pctxArchInfo :: !(ArchitectureInfo arch)
                                          , pctxFunAddr  :: !(ArchSegmentOff arch)
                                            -- ^ Address of function this block is being parsed as
                                          , pctxAddr     :: !(ArchSegmentOff arch)
                                             -- ^ Address of the current block
                                          , pctxBlockMap :: !(Map Word64 (Block arch ids))
                                          }

addrMemRepr :: ArchitectureInfo arch -> MemRepr (BVType (RegAddrWidth (ArchReg arch)))
addrMemRepr arch_info =
  case archAddrWidth arch_info of
    Addr32 -> BVMemRepr n4 (archEndianness arch_info)
    Addr64 -> BVMemRepr n8 (archEndianness arch_info)

-- | This parses a block that ended with a fetch and execute instruction.
parseFetchAndExecute :: forall arch ids
                     .  ParseContext arch ids
                     -> Word64
                        -- ^ Index of this block
                     -> [Stmt arch ids]
                     -> AbsProcessorState (ArchReg arch) ids
                     -- ^ Registers prior to blocks being executed.
                     -> RegState (ArchReg arch) (Value arch ids)
                     -> State (ParseState arch ids) (StatementList arch ids)
parseFetchAndExecute ctx lbl_idx stmts regs s' = do
  let src = pctxAddr ctx
  let mem = pctxMemory ctx
  let arch_info = pctxArchInfo ctx
  withArchConstraints arch_info $ do
  -- See if next statement appears to end with a call.
  -- We define calls as statements that end with a write that
  -- stores the pc to an address.
  let absProcState' = absEvalStmts arch_info regs stmts
  case () of
    -- The last statement was a call.
    -- Note that in some cases the call is known not to return, and thus
    -- this code will never jump to the return value.
    _ | Just (prev_stmts, ret) <- identifyCall mem stmts s'  -> do
        mapM_ (recordWriteStmt arch_info mem absProcState') prev_stmts
        let abst = finalAbsBlockState absProcState' s'
        seq abst $ do
        -- Merge caller return information
        intraJumpTargets %= ((ret, postCallAbsState arch_info abst ret):)
        -- Look for new ips.
        let addrs = concretizeAbsCodePointers mem (abst^.absRegState^.curIP)
        newFunctionAddrs %= (++ addrs)
        pure StatementList { stmtsIdent = lbl_idx
                           , stmtsNonterm = toList prev_stmts
                           , stmtsTerm  = ParsedCall s' (Just ret)
                           , stmtsAbsState = absProcState'
                           }

    -- This block ends with a return.
      | ReturnAddr <- transferValue absProcState' (s'^.boundValue ip_reg) -> do
        mapM_ (recordWriteStmt arch_info mem absProcState') stmts

        pure StatementList { stmtsIdent = lbl_idx
                           , stmtsNonterm = stmts
                           , stmtsTerm = ParsedReturn s'
                           , stmtsAbsState = absProcState'
                           }

      -- Jump to concrete offset.
      --
      -- Note, we disallow jumps back to function entry point thus forcing them to be treated
      -- as tail calls or unclassified if the stack has changed size.
      | Just tgt_addr <- asLiteralAddr (s'^.boundValue ip_reg)
      , Just tgt_mseg <- asSegmentOff mem tgt_addr
      , segmentFlags (msegSegment tgt_mseg) `Perm.hasPerm` Perm.execute
      , tgt_mseg /= pctxFunAddr ctx -> do
         mapM_ (recordWriteStmt arch_info mem absProcState') stmts
         -- Merge block state and add intra jump target.
         let abst = finalAbsBlockState absProcState' s'
         let abst' = abst & setAbsIP tgt_mseg
         intraJumpTargets %= ((tgt_mseg, abst'):)
         pure StatementList { stmtsIdent = lbl_idx
                            , stmtsNonterm = stmts
                            , stmtsTerm  = ParsedJump s' tgt_mseg
                            , stmtsAbsState = absProcState'
                            }
      -- Block ends with what looks like a jump table.
      | AssignedValue (Assignment _ (ReadMem ptr _)) <- debug DCFG "try jump table" $ s'^.curIP
        -- Attempt to compute interval of addresses interval is over.
      , Just (base, jump_idx) <- matchJumpTable mem ptr ->
        case getJumpTableBounds arch_info absProcState' base jump_idx of
          Left err ->
            trace (show src ++ ": Could not compute bounds: " ++ showJumpTableBoundsError err) $ do
            mapM_ (recordWriteStmt arch_info mem absProcState') stmts
            pure StatementList { stmtsIdent = lbl_idx
                               , stmtsNonterm = stmts
                               , stmtsTerm  = ClassifyFailure s'
                               , stmtsAbsState = absProcState'
                               }
          Right read_end -> do
            mapM_ (recordWriteStmt arch_info mem absProcState') stmts

            -- Try to compute jump table bounds

            let abst :: AbsBlockState (ArchReg arch)
                abst = finalAbsBlockState absProcState' s'
            seq abst $ do
            -- This function resolves jump table entries.
            -- It is a recursive function that has an index into the jump table.
            -- If the current index can be interpreted as a intra-procedural jump,
            -- then it will add that to the current procedure.
            -- This returns the last address read.
            let resolveJump :: [ArchSegmentOff arch]
                               -- /\ Addresses in jump table in reverse order
                            -> ArchAddrWord arch
                               -- /\ Current index
                            -> State (ParseState arch ids) [ArchSegmentOff arch]
                resolveJump prev idx | idx == read_end = do
                  -- Stop jump table when we have reached computed bounds.
                  return (reverse prev)
                resolveJump prev idx = do
                  let read_addr = base & incAddr (toInteger (8 * idx))
                  case readAddr mem (archEndianness arch_info) read_addr of
                      Right tgt_addr
                        | Just read_mseg <- asSegmentOff mem read_addr
                        , Perm.isReadonly (segmentFlags (msegSegment read_mseg))
                        , Just tgt_mseg <- asSegmentOff mem tgt_addr
                        , Perm.isExecutable (segmentFlags (msegSegment tgt_mseg)) -> do
                          let abst' = abst & setAbsIP tgt_mseg
                          intraJumpTargets %= ((tgt_mseg, abst'):)
                          resolveJump (tgt_mseg:prev) (idx+1)
                      _ -> do
                        debug DCFG ("Stop jump table: " ++ show idx ++ " " ++ show read_end) $ do
                          return (reverse prev)
            read_addrs <- resolveJump [] 0
            pure StatementList { stmtsIdent = lbl_idx
                               , stmtsNonterm = stmts
                               , stmtsTerm = ParsedLookupTable s' jump_idx (V.fromList read_addrs)
                               , stmtsAbsState = absProcState'
                               }

      -- Check for tail call (anything where we are right at stack height
      | ptrType    <- addrMemRepr arch_info
      , sp_val     <-  s'^.boundValue sp_reg
      , ReturnAddr <- absEvalReadMem absProcState' sp_val ptrType -> do

        mapM_ (recordWriteStmt arch_info mem absProcState') stmts

        -- Compute fina lstate
        let abst = finalAbsBlockState absProcState' s'
        seq abst $ do

        -- Look for new instruction pointers
        let addrs = concretizeAbsCodePointers mem (abst^.absRegState^.curIP)
        newFunctionAddrs %= (++ addrs)


        pure StatementList { stmtsIdent = lbl_idx
                           , stmtsNonterm = stmts
                           , stmtsTerm  = ParsedCall s' Nothing
                           , stmtsAbsState = absProcState'
                           }

      -- Block that ends with some unknown
      | otherwise -> do
          mapM_ (recordWriteStmt arch_info mem absProcState') stmts
          pure StatementList { stmtsIdent = lbl_idx
                             , stmtsNonterm = stmts
                             , stmtsTerm  = ClassifyFailure s'
                             , stmtsAbsState = absProcState'
                             }

-- | this evalutes the statements in a block to expand the information known
-- about control flow targets of this block.
parseBlock :: ParseContext arch ids
              -- ^ Context for parsing blocks.
           -> Block arch ids
              -- ^ Block to parse
           -> AbsProcessorState (ArchReg arch) ids
              -- ^ Abstract state at start of block
           -> State (ParseState arch ids) (StatementList arch ids)
parseBlock ctx b regs = do
  let mem       = pctxMemory ctx
  let arch_info = pctxArchInfo ctx
  withArchConstraints arch_info $ do
  let idx = blockLabel b
  let block_map = pctxBlockMap ctx
  -- FIXME: we should propagate c back to the initial block, not just b
  let absProcState' = absEvalStmts arch_info regs (blockStmts b)
  case blockTerm b of
    Branch c lb rb -> do
      mapM_ (recordWriteStmt arch_info mem absProcState') (blockStmts b)

      let Just l = Map.lookup lb block_map
      let l_regs = refineProcStateBounds c True $ refineProcState c absTrue absProcState'
      let Just r = Map.lookup rb block_map
      let r_regs = refineProcStateBounds c False $ refineProcState c absFalse absProcState'

      let l_regs' = absEvalStmts arch_info l_regs (blockStmts b)
      let r_regs' = absEvalStmts arch_info r_regs (blockStmts b)

      parsedTrueBlock  <- parseBlock ctx l l_regs'
      parsedFalseBlock <- parseBlock ctx r r_regs'

      pure $! StatementList { stmtsIdent = idx
                            , stmtsNonterm = blockStmts b
                            , stmtsTerm  = ParsedIte c parsedTrueBlock parsedFalseBlock
                            , stmtsAbsState = absProcState'
                            }

    Syscall s' -> do
      mapM_ (recordWriteStmt arch_info mem absProcState') (blockStmts b)
      let abst = finalAbsBlockState absProcState' s'
      case concretizeAbsCodePointers mem (abst^.absRegState^.curIP) of
        [] -> error "Could not identify concrete system call address"
        [addr] -> do
          -- Merge system call result with possible next IPs.
          let post = archPostSyscallAbsState arch_info abst addr

          intraJumpTargets %= ((addr, post):)
          pure $! StatementList { stmtsIdent = idx
                                , stmtsNonterm = blockStmts b
                                , stmtsTerm  = ParsedSyscall s' addr
                                , stmtsAbsState = absProcState'
                                }
        _ -> error "Multiple system call addresses."


    FetchAndExecute s' -> do
      parseFetchAndExecute ctx idx (blockStmts b) regs s'

    -- Do nothing when this block ends in a translation error.
    TranslateError _ msg -> do
      pure $! StatementList { stmtsIdent = idx
                            , stmtsNonterm = blockStmts b
                            , stmtsTerm = ParsedTranslateError msg
                            , stmtsAbsState = absProcState'
                            }

-- | This evalutes the statements in a block to expand the information known
-- about control flow targets of this block.
transferBlocks :: ArchSegmentOff arch
                  -- ^ Address of theze blocks
               -> FoundAddr arch
                  -- ^ State leading to explore block
               -> ArchAddrWord arch
                  -- ^ Size of the region these blocks cover.
               -> Map Word64 (Block arch ids)
                  -- ^ Map from labelIndex to associated block
               -> FunM arch ids ()
transferBlocks src finfo sz block_map =
  case Map.lookup 0 block_map of
    Nothing -> do
      error $ "transferBlocks given empty blockRegion."
    Just b -> do
      mem       <- uses curFunCtx memory
      let regs = initAbsProcessorState mem (foundAbstractState finfo)
      funAddr <- gets curFunAddr
      s <- use curFunCtx
      let ctx = ParseContext { pctxMemory   = memory s
                             , pctxArchInfo = archInfo s
                             , pctxFunAddr  = funAddr
                             , pctxAddr     = src
                             , pctxBlockMap = block_map
                             }
      let ps0 = ParseState { _writtenCodeAddrs = []
                           , _intraJumpTargets = []
                           , _newFunctionAddrs = []
                           }
      let (pblock, ps) = runState (parseBlock ctx b regs) ps0
      let pb = ParsedBlock { pblockAddr = src
                           , blockSize = sz
                           , blockReason = foundReason finfo
                           , blockAbstractState = foundAbstractState finfo
                           , blockStatementList = pblock
                           }
      curFunBlocks %= Map.insert src pb
      curFunCtx %= markAddrsAsFunction (InWrite src)    (ps^.writtenCodeAddrs)
                .  markAddrsAsFunction (CallTarget src) (ps^.newFunctionAddrs)
      mapM_ (\(addr, abs_state) -> mergeIntraJump src abs_state addr) (ps^.intraJumpTargets)


transfer :: ArchSegmentOff arch
         -> FunM arch ids ()
transfer addr = do
  s <- use curFunCtx
  let ainfo = archInfo s
  withArchConstraints ainfo $ do
  mfinfo <- use $ foundAddrs . at addr
  let finfo = fromMaybe (error $ "transfer called on unfound address " ++ show addr ++ ".") $
                mfinfo
  let mem = memory s
  nonceGen <- gets funNonceGen
  prev_block_map <- use $ curFunBlocks
  -- Get maximum number of bytes to disassemble
  let seg = msegSegment addr
      off = msegOffset addr
  let max_size =
        case Map.lookupGT addr prev_block_map of
          Just (next,_) | Just o <- diffSegmentOff next addr -> fromInteger o
          _ -> segmentSize seg - off
  let ab = foundAbstractState finfo
  (bs0, sz, maybeError) <-
    liftST $ disassembleFn ainfo mem nonceGen addr max_size ab
  -- If no blocks are returned, then we just add an empty parsed block.
  if null bs0 then do
    let errMsg = Text.pack $ fromMaybe "Unknown error" maybeError
    let stmts = StatementList
          { stmtsIdent = 0
          , stmtsNonterm = []
          , stmtsTerm = ParsedTranslateError errMsg
          , stmtsAbsState = initAbsProcessorState mem (foundAbstractState finfo)
          }
    let pb = ParsedBlock { pblockAddr = addr
                         , blockSize = sz
                         , blockReason = foundReason finfo
                         , blockAbstractState = foundAbstractState finfo
                         , blockStatementList = stmts
                         }
    curFunBlocks %= Map.insert addr pb
   else do
    -- Rewrite returned blocks to simplify expressions
    let ctx = RewriteContext { rwctxNonceGen = nonceGen
                             , rwctxArchFn   = rewriteArchFn ainfo
                             , rwctxArchStmt = rewriteArchStmt ainfo
                             , rwctxConstraints = \x -> x
                             }
    bs1 <- liftST $ runRewriter ctx $ traverse rewriteBlock bs0
    -- Comute demand set
    let demandSet =
          runDemandComp (archDemandContext ainfo) $ do
            traverse_ addBlockDemands bs1
    let bs = elimDeadBlockStmts demandSet <$> bs1
    -- Call transfer blocks to calculate parsedblocks
    let block_map = Map.fromList [ (blockLabel b, b) | b <- bs ]
    transferBlocks addr finfo sz block_map

------------------------------------------------------------------------
-- Main loop

-- | Loop that repeatedly explore blocks until we have explored blocks
-- on the frontier.
analyzeBlocks :: FunM arch ids ()
analyzeBlocks = do
  st <- FunM get
  case Set.minView (st^.frontier) of
    Nothing -> return ()
    Just (addr, next_roots) -> do
      FunM $ put $ st & frontier .~ next_roots
      transfer addr
      analyzeBlocks

-- | This analyzes the function at a given address, possibly
-- discovering new candidates.
--
-- This returns the updated state and the discovered control flow
-- graph for this function.
analyzeFunction :: ArchSegmentOff arch
                   -- ^ The address to explore
                -> CodeAddrReason (ArchAddrWidth arch)
                -- ^ Reason to provide for why we are analyzing this function
                --
                -- This can be used to figure out why we decided a
                -- given address identified a code location.
                -> DiscoveryState arch
                -- ^ The current binary information.
                -> (DiscoveryState arch, Some (DiscoveryFunInfo arch))
analyzeFunction addr rsn s = do
  case Map.lookup addr (s^.funInfo) of
    Just finfo -> (s, finfo)
    Nothing -> do
      let info = archInfo s
      withArchConstraints info $ do
      withGlobalSTNonceGenerator $ \gen -> do
      let mem  = memory s

      let faddr = FoundAddr { foundReason = rsn
                            , foundAbstractState = mkInitialAbsState info mem addr
                            }

      let fs0 = FunState { funNonceGen = gen
                         , curFunAddr  = addr
                         , _curFunCtx  = s
                         , _curFunBlocks = Map.empty
                         , _foundAddrs = Map.singleton addr faddr
                         , _reverseEdges = Map.empty
                         , _frontier   = Set.singleton addr
                         }
      fs <- execStateT (unFunM analyzeBlocks) fs0
      let nm = fromMaybe (BSC.pack (show addr)) (symbolAtAddr addr (symbolNames s))
      let finfo = DiscoveryFunInfo { discoveredFunAddr = addr
                                   , discoveredFunName = nm
                                   , _parsedBlocks = fs^.curFunBlocks
                                   }
      let s' = (fs^.curFunCtx)
             & funInfo             %~ Map.insert addr (Some finfo)
             & unexploredFunctions %~ Map.delete addr
      pure (s', Some finfo)

-- | Analyze addresses that we have marked as functions, but not yet analyzed to
-- identify basic blocks, and discover new function candidates until we have
-- analyzed all function entry points.
analyzeDiscoveredFunctions :: DiscoveryState arch -> DiscoveryState arch
analyzeDiscoveredFunctions info =
  case Map.lookupMin (info^.unexploredFunctions) of
    Nothing -> info
    Just (addr, rsn) ->
      analyzeDiscoveredFunctions $! fst (analyzeFunction addr rsn info)

-- | This returns true if the address is writable and value is executable.
isDataCodePointer :: MemSegmentOff w -> MemSegmentOff w -> Bool
isDataCodePointer a v
  =  segmentFlags (msegSegment a) `Perm.hasPerm` Perm.write
  && segmentFlags (msegSegment v) `Perm.hasPerm` Perm.execute

addMemCodePointer :: (ArchSegmentOff arch, ArchSegmentOff arch)
                  -> DiscoveryState arch
                  -> DiscoveryState arch
addMemCodePointer (src,val) = markAddrAsFunction (CodePointerInMem src) val

exploreMemPointers :: [(ArchSegmentOff arch, ArchSegmentOff arch)]
                   -- ^ List of addresses and value pairs to use for
                   -- considering possible addresses.
                   -> DiscoveryState arch
                   -> DiscoveryState arch
exploreMemPointers mem_words info =
  flip execState info $ do
    let mem_addrs
          = filter (\(a,v) -> isDataCodePointer a v)
          $ mem_words
    mapM_ (modify . addMemCodePointer) mem_addrs

-- | Construct a discovery info by starting with exploring from a given set of
-- function entry points.
cfgFromAddrs :: forall arch
             .  ArchitectureInfo arch
                -- ^ Architecture-specific information needed for doing control-flow exploration.
             -> Memory (ArchAddrWidth arch)
                -- ^ Memory to use when decoding instructions.
             -> SymbolAddrMap (ArchAddrWidth arch)
                -- ^ Map from addresses to the associated symbol name.
             -> [ArchSegmentOff arch]
                -- ^ Initial function entry points.
             -> [(ArchSegmentOff arch, ArchSegmentOff arch)]
                -- ^ Function entry points in memory to be explored
                -- after exploring function entry points.
                --
                -- Each entry contains an address and the value stored in it.
             -> DiscoveryState arch
cfgFromAddrs arch_info mem symbols init_addrs mem_words = do
  emptyDiscoveryState mem symbols arch_info
    & markAddrsAsFunction InitAddr init_addrs
    & analyzeDiscoveredFunctions
    & exploreMemPointers mem_words
    & analyzeDiscoveredFunctions
