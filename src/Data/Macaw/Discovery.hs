{- |
Module           : Reopt.Semantics.CFGDiscovery
Copyright        : (c) Galois, Inc 2015-2016
Maintainer       : Joe Hendrix <jhendrix@galois.com>, Simon Winwood <sjw@galois.com>

This contains an implementation of a CFG discovery algorithm based upon an
interleaved abstract interpretation.
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
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Data.Macaw.Discovery
       ( DiscoveryConstraints
       , cfgFromAddrs
       , assignmentAbsValues
       ) where

import           Control.Exception
import           Control.Lens
import           Control.Monad.ST
import           Control.Monad.State.Strict
import qualified Data.ByteString as BS
import qualified Data.Foldable as Fold
import           Data.List
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Parameterized.Classes
import           Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.NatRepr
import           Data.Parameterized.Nonce
import           Data.Parameterized.Some
import qualified Data.Set as Set
import           Data.Word
import           Numeric
--import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import           Data.Macaw.AbsDomain.AbsState
import           Data.Macaw.AbsDomain.Refine
import qualified Data.Macaw.AbsDomain.StridedInterval as SI
import           Data.Macaw.Architecture.Info
import           Data.Macaw.CFG
import           Data.Macaw.DebugLogging
import           Data.Macaw.Discovery.Info
--import           Data.Macaw.Discovery.JumpBounds
import           Data.Macaw.Memory
import qualified Data.Macaw.Memory.Permissions as Perm
import           Data.Macaw.Types

transferRHS :: forall a ids tp
            .  ( OrdF (ArchReg a)
               , ShowF (ArchReg a)
               , MemWidth (ArchAddrWidth a)
               )
            => ArchitectureInfo a
            -> AbsProcessorState (ArchReg a) ids
            -> AssignRhs a ids tp
            -> ArchAbsValue a tp
transferRHS info r rhs =
  case rhs of
    EvalApp app    -> transferApp r app
    SetUndefined _ -> TopV
    ReadMem a tp
      | StackOffset _ s <- transferValue r a
      , [o] <- Set.toList s
      , Just (StackEntry v_tp v) <- Map.lookup o (r^.curAbsStack)
      , Just Refl <- testEquality tp v_tp ->
         v
      | otherwise -> TopV
    EvalArchFn f _ -> absEvalArchFn info r f

-- | Merge in the value of the assignment.
--
-- If we have already seen a value, this will combine with meet.
addAssignment :: ( OrdF  (ArchReg a)
                 , ShowF (ArchReg a)
                 , MemWidth (ArchAddrWidth a)
                 )
              => ArchitectureInfo a
              -> Assignment a ids tp
              -> AbsProcessorState (ArchReg a) ids
              -> AbsProcessorState (ArchReg a) ids
addAssignment info a c =
  c & (absAssignments . assignLens (assignId a))
    %~ flip meet (transferRHS info c (assignRhs a))

------------------------------------------------------------------------
-- Utilities

-- | Get code pointers out of a abstract value.
concretizeAbsCodePointers :: MemWidth w
                          => Memory w
                          -> AbsValue w (BVType w)
                          -> [SegmentedAddr w]
concretizeAbsCodePointers mem (FinSet s) =
  [ sa
  | a <- Set.toList s
  , Just sa <- [absoluteAddrSegment mem (fromInteger a)]
  , Perm.isExecutable (segmentFlags (addrSegment sa))
  ]
concretizeAbsCodePointers _ (CodePointers s _) =
  [ sa
  | sa <- Set.toList s
  , Perm.isExecutable (segmentFlags (addrSegment sa))
  ]
  -- FIXME: this is dangerous !!
concretizeAbsCodePointers _mem StridedInterval{} = [] -- FIXME: this case doesn't make sense
  -- debug DCFG ("I think these are code pointers!: " ++ show s) $ []
  -- filter (isCodeAddr mem) $ fromInteger <$> SI.toList s
concretizeAbsCodePointers _mem _ = []

-- | @deleteMapRange l h m@ deletes all entries with keys greater than @l@ and
-- less than @h@.
deleteMapRange :: Ord k => Maybe k -> Maybe k -> Map k v -> Map k v
deleteMapRange (Just l) (Just h) m =
  case Map.splitLookup l m of
    (lm, Nothing, hm) -> Map.union lm (deleteMapLessThan h hm)
    (lm, Just v,  hm) -> Map.union (Map.insert l v lm) (deleteMapLessThan h hm)
deleteMapRange (Just l) Nothing  m = deleteMapGreaterThan l m
deleteMapRange Nothing  (Just h) m = deleteMapLessThan h m
deleteMapRange Nothing  Nothing  m = m

-- | @deleteMapGreaterThan k m@ returns a map with all keys greater than @k@ in @m@ deleted.
deleteMapGreaterThan :: Ord k => k -> Map k v -> Map k v
deleteMapGreaterThan k m =
  case Map.splitLookup k m of
    (lm, Nothing, _) -> lm
    (lm, Just v, _)  -> Map.insert k v lm

-- | @deleteMapLessThan k m@ returns a map with all keys less than @k@ in @m@ deleted.
deleteMapLessThan :: Ord k => k -> Map k v -> Map k v
deleteMapLessThan k m =
  case Map.splitLookup k m of
    (_, Nothing, hm) -> hm
    (_, Just v, hm) -> Map.insert k v hm

------------------------------------------------------------------------
-- Memory utilities

-- | Return true if range is entirely contained within a single read only segment.Q
rangeInReadonlySegment :: MemWidth w
                       => SegmentedAddr w -- ^ Start of range
                       -> MemWord w -- ^ The size of the range
                       -> Bool
rangeInReadonlySegment base size
    = base^.addrOffset + size <= segmentSize seg
    && Perm.isReadonly (segmentFlags seg)
  where seg = addrSegment base


------------------------------------------------------------------------
-- Block discovery

-- | The CFG-building monad: includes a state component with a 'DiscoveryInfo'
-- and a 'NonceGenerator', layered on top of the 'ST' monad
newtype CFGM arch ids a =
    CFGM { unCFGM :: StateT (DiscoveryInfo arch ids) (ST ids) a }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadState (DiscoveryInfo arch ids)
           )

liftST :: ST ids a -> CFGM arch ids a
liftST = CFGM . lift

-- | Run a CFGM at the top level
runCFGM :: ArchitectureInfo arch
           -- ^ Architecture-specific information needed for doing control-flow exploration.
        -> Memory (ArchAddrWidth arch)
           -- ^ Memory to use when decoding instructions.
        -> Map (ArchSegmentedAddr arch) BS.ByteString
           -- ^ Names for (some) function entry points
        -> (forall ids . CFGM arch ids ())
           -- ^ Computation to run.
        -> Some (DiscoveryInfo arch)
runCFGM arch_info mem symbols m = do
  withGlobalSTNonceGenerator $ \nonce_gen -> do
    let init_info = emptyDiscoveryInfo nonce_gen mem symbols arch_info
    Some <$> execStateT (unCFGM m) init_info

printAddrBacktrace :: Map (ArchSegmentedAddr arch) (BlockRegion arch ids)
                   -> CodeAddrReason (ArchAddrWidth arch)
                   -> [String]
printAddrBacktrace m rsn = do
  let prev addr =
        case Map.lookup addr m of
          Just br -> printAddrBacktrace m (brReason br)
          Nothing -> error $ "Unknown reason for address " ++ show addr
  case rsn of
    InWrite src ->
      ["Written to memory in block at address " ++ show src ++ "."]
      ++ prev src
    NextIP src ->
      ["Target IP for " ++ show src ++ "."]
      ++ prev src
    CallTarget src ->
      ["Target IP of call at " ++ show src ++ "."]
      ++ prev src

    InitAddr -> ["Initial entry point"]
    CodePointerInMem src -> ["Memory address " ++ show src ++ " contained code."]
    SplitAt src -> ["Split from read of " ++ show src ++ "."] ++ prev src
    InterProcedureJump src -> ["Reference from external address " ++ show src ++ "."] ++ prev src

-- | Return true if this address was added because of the contents of a global address
-- in memory initially.
--
-- This heuristic is not very accurate, so we avoid printing errors when it leads to
-- issues.
cameFromInitialMemoryContents :: Map (ArchSegmentedAddr arch) (BlockRegion arch ids)
                              -> CodeAddrReason (ArchAddrWidth arch)
                              -> Bool
cameFromInitialMemoryContents m rsn = do
  let prev addr =
        case Map.lookup addr m of
          Just br -> cameFromInitialMemoryContents m (brReason br)
          Nothing -> error $ "Unknown reason for address " ++ show addr
  case rsn of
    InWrite src -> prev src
    NextIP src  -> prev src
    CallTarget src -> prev src
    SplitAt src -> prev src
    InitAddr -> False
    CodePointerInMem{} -> True
    InterProcedureJump src -> prev src

-- | This is the worker for getBlock, in the case that we have not already
-- read the block.
tryDisassembleAddr :: PrettyCFGConstraints arch
                   => CodeAddrReason (ArchAddrWidth arch)
                       -- ^ Reason we are trying to disassemble starting from given address
                   -> ArchSegmentedAddr arch
                      -- ^ Address to disassemble
                   -> AbsBlockState (ArchReg arch)
                      -- ^ Abstract state at beginning of block
                   -> CFGM arch ids ()
tryDisassembleAddr rsn addr ab = do
  s0 <- get
  -- Attempt to disassemble block.
  -- Get memory so that we can decode from it.
  let block_addrs = s0^.blocks
  -- Returns true if we are not at the start of a block.
  -- This is used to stop the disassembler when we reach code
  -- that is part of a new block.
  let not_at_block = (`Map.notMember` block_addrs)
  let mem = memory s0
  nonce_gen <- nonceGen <$> get
  (bs, next_ip, maybeError) <- liftST $ disassembleFn (archInfo s0) nonce_gen mem not_at_block addr ab
  -- Build state for exploring this.
  case maybeError of
    Just e -> do
      when (not (cameFromInitialMemoryContents block_addrs rsn)) $ do
          error $ "Failed to disassemble " ++ show e ++ "\n"
            ++ unlines (printAddrBacktrace block_addrs rsn)
    Nothing -> do
      pure ()
  assert (segmentIndex (addrSegment next_ip) == segmentIndex (addrSegment addr)) $ do
  assert (next_ip^.addrOffset > addr^.addrOffset) $ do
  let block_map = Map.fromList [ (labelIndex (blockLabel b), b) | b <- bs ]
  -- Add block region to blocks.
  let br = BlockRegion { brReason = rsn
                       , brSize = next_ip^.addrOffset - addr^.addrOffset
                       , brBlocks = block_map
                       , brAbsInitState = ab
                       }
  put $ s0 & blocks %~ Map.insert addr br

-- | Mark address as the start of a code block.
markCodeAddrBlock :: PrettyCFGConstraints arch
                  => CodeAddrReason (ArchAddrWidth arch)
                      -- ^ Reason we are trying to disassemble starting from given address
                  -> ArchSegmentedAddr arch
                     -- ^ Address to start disassembling
                  -> AbsBlockState (ArchReg arch)
                     -- ^ Abstract block state at start of disassembly
                  -> CFGM arch ids ()
markCodeAddrBlock rsn addr ab = do
  s <- get
  -- Lookup block just before this address
  case Map.lookupLT addr (s^.blocks) of
    -- If that block overlaps with the address
    Just (l, br)
      | segmentIndex (addrSegment addr) == segmentIndex (addrSegment l)
      , addr^.addrOffset < l^.addrOffset + brSize br -> do
      -- Get block for addr
      tryDisassembleAddr rsn addr ab
      -- Get block for old block
      tryDisassembleAddr (brReason br) l (brAbsInitState br)
      -- It's possible this will cause the current block to be broken, or cause a function to
      -- boundaries.  However, we don't think this should cause the need automatically to
      -- re-evaluate a block as any information discovered should be strictly less than
      -- the longer block.
    _ -> do
      tryDisassembleAddr rsn addr ab

------------------------------------------------------------------------
-- Transfer stmts

transferStmt :: ( RegisterInfo (ArchReg arch)
                , HasRepr (ArchReg arch) TypeRepr
                , MemWidth (ArchAddrWidth arch)
                )
             => ArchitectureInfo arch
             -> Stmt arch ids
             -> State (AbsProcessorState (ArchReg arch) ids) ()
transferStmt info stmt =
  case stmt of
    AssignStmt a -> do
      modify $ addAssignment info a
    WriteMem addr v -> do
      modify $ \r -> addMemWrite (r^.absInitialRegs^.curIP) addr v r
    _ -> return ()


newtype HexWord = HexWord Word64

instance Show HexWord where
  showsPrec _ (HexWord w) = showHex w

-- | Mark a escaped code pointer as a function entry.
markAddrAsFunction :: PrettyCFGConstraints arch
                   => CodeAddrReason (ArchAddrWidth arch)
                   -> ArchSegmentedAddr arch
                   -> CFGM arch ids ()
markAddrAsFunction rsn addr = do
  s <- get
  when (not (Set.member addr (s^.functionEntries))) $ do
    debugM DCFG ("Found function entry " ++ show addr ++ ".")
    let mem = memory s
    let low = Set.lookupLT addr (s^.functionEntries)
    let _high = Set.lookupGT addr (s^.functionEntries)
    -- Get abstract state associated with function begining at address
    let abstState = fnBlockStateFn (archInfo s) mem addr
    modify $ (functionEntries   %~ Set.insert addr)
           . (function_frontier %~ (maybeMapInsert low (SplitAt addr) .  Map.insert addr rsn))
    markCodeAddrBlock rsn addr abstState

maybeMapInsert :: Ord a => Maybe a -> b -> Map a b -> Map a b
maybeMapInsert mk v = maybe id (\k -> Map.insert k v) mk

-- | Mark addresses written to memory that point to code as function entry points.
recordWriteStmt :: ( PrettyCFGConstraints arch
                   , HasRepr (ArchReg arch) TypeRepr
                   , MemWidth (ArchAddrWidth arch)
                   )
                => SegmentedAddr (ArchAddrWidth arch)
                   -- ^ Start of block containing write
                -> AbsProcessorState (ArchReg arch) ids
                -> Stmt arch ids
                -> CFGM arch ids ()
recordWriteStmt src regs stmt = do
  addrWidth <- gets $ addrWidthNatRepr . archAddrWidth . archInfo
  case stmt of
    WriteMem _addr v
      | Just Refl <- testEquality (typeRepr v) (BVTypeRepr addrWidth) -> do
          mem <- gets memory
          let addrs = concretizeAbsCodePointers mem (transferValue regs v)
          mapM_ (markAddrAsFunction (InWrite src)) addrs
    _ -> return ()

transferStmts :: ( HasRepr      (ArchReg arch) TypeRepr
                 , RegisterInfo (ArchReg arch)
                 , MemWidth (ArchAddrWidth arch)
                 )
              => ArchitectureInfo arch
              -> AbsProcessorState (ArchReg arch) ids
              -> [Stmt arch ids]
              -> AbsProcessorState (ArchReg arch) ids
transferStmts info r stmts = execState (mapM_ (transferStmt info) stmts) r

-- | Generate map that maps each assignment in the CFG to the abstract value
-- associated with it.
assignmentAbsValues :: forall arch ids
                    .  ( HasRepr      (ArchReg arch) TypeRepr
                       , RegisterInfo (ArchReg arch)
                       , MemWidth (ArchAddrWidth arch)
                       )
                    => ArchitectureInfo arch
                    -> Memory (ArchAddrWidth arch)
                    -> CFG arch ids
                    -> Map (ArchSegmentedAddr arch) (AbsBlockState (ArchReg arch))
                       -- ^ Maps addresses to the initial state at that address.
                    -> MapF (AssignId ids) (ArchAbsValue arch)
assignmentAbsValues info mem g absm =
     foldl' go MapF.empty (Map.elems (g^.cfgBlocks))
  where go :: MapF (AssignId ids) (ArchAbsValue arch)
           -> Block arch ids
           -> MapF (AssignId ids) (ArchAbsValue arch)
        go m0 b =
          case blockLabel b of
            GeneratedBlock a 0 -> do
              case Map.lookup a absm of
                Nothing -> do
                  error $ "assignmentAbsValues could not find code infomation for block " ++ show a
                Just blockState -> do
                  let abs_state = initAbsProcessorState mem blockState
                  insBlock b abs_state m0
            _ -> m0

        insBlock :: Block arch ids
                 -> AbsProcessorState (ArchReg arch) ids
                 -> MapF (AssignId ids) (ArchAbsValue arch)
                 -> MapF (AssignId ids) (ArchAbsValue arch)
        insBlock b r0 m0 =
          let final = transferStmts info r0 (blockStmts b)
              m = MapF.union (final^.absAssignments) m0 in
          case blockTerm b of
            Branch _ lb rb -> do
              let Just l = findBlock g lb
              let Just r = findBlock g rb
              insBlock l final $
                insBlock r final $
                m
            FetchAndExecute _ -> m
            Syscall _ -> m
            TranslateError{} -> m

------------------------------------------------------------------------
-- Transfer functions

-- | Joins in the new abstract state and returns the locations for
-- which the new state is changed.
mergeIntraJump  :: ( PrettyCFGConstraints arch
                   , RegisterInfo (ArchReg arch)
                   )
                => BlockLabel (ArchAddrWidth arch)
                  -- ^ Source label that we are jumping from.
                -> AbsBlockState (ArchReg arch)
                   -- ^ Block state after executing instructions.
                -> ArchSegmentedAddr arch
                   -- ^ Address we are trying to reach.
                -> CFGM arch ids ()
mergeIntraJump src ab _tgt
  | not (absStackHasReturnAddr ab)
  , debug DCFG ("WARNING: Missing return value in jump from " ++ show src ++ " to\n" ++ show ab) False
  = error "Unexpected mergeIntraJump"
mergeIntraJump src ab tgt = do
  let rsn = NextIP (labelAddr src)
  -- Associate a new abstract state with the code region.
  s0 <- get
  case Map.lookup tgt (s0^.blocks) of
    -- We have seen this block before, so need to join and see if
    -- the results is changed.
    Just old_block -> do
      case joinD (brAbsInitState old_block) ab of
        Nothing  -> return ()
        Just new -> do
          let new_block = old_block { brAbsInitState = new }
          modify $ (blocks       %~ Map.insert tgt new_block)
                 . (reverseEdges %~ Map.insertWith Set.union tgt (Set.singleton (labelAddr src)))
                 . (frontier     %~ Map.insert tgt rsn)
    -- We haven't seen this block before
    Nothing -> do
      modify $ (reverseEdges %~ Map.insertWith Set.union tgt (Set.singleton (labelAddr src)))
             . (frontier     %~ Map.insert tgt rsn)
      markCodeAddrBlock rsn tgt ab


-- -----------------------------------------------------------------------------
-- Refining an abstract state based upon a condition


-- See if expression matches form expected by jump tables
-- TODO: Fixme, this uses a fixed multiple of 8 for the jump table
matchJumpTable :: MemWidth (ArchAddrWidth arch)
               => Memory (ArchAddrWidth arch)
               -> BVValue arch ids (ArchAddrWidth arch) -- ^ Memory address that IP is read from.
               -> Maybe (ArchSegmentedAddr arch, BVValue arch ids (ArchAddrWidth arch))
matchJumpTable mem read_addr
    -- Turn the read address into base + offset.
  | Just (BVAdd _ offset base_val) <- valueAsApp read_addr
  , Just base <- asLiteralAddr mem base_val
    -- Turn the offset into a multiple by an index.
  , Just (BVMul _ (BVValue _ mul) jump_index) <- valueAsApp offset
  , mul == addrWidthByteSize (memAddrWidth mem)
  , Perm.isReadonly (segmentFlags (addrSegment base)) = do
    Just (base, jump_index)
matchJumpTable _ _ =
    Nothing

-- Returns the index bounds for a jump table of 'Nothing' if this is not a block
-- table.
getJumpTableBounds :: ( OrdF (ArchReg a)
                      , ShowF (ArchReg a)
                      , MemWidth (ArchAddrWidth a)
                      )
                   => AbsProcessorState (ArchReg a) ids -- ^ Current processor registers.
                   -> ArchSegmentedAddr a -- ^ Base
                   -> BVValue a ids (ArchAddrWidth a) -- ^ Index in jump table
                   -> Maybe (ArchAddr a)
                   -- ^ One past last index in jump table or nothing
getJumpTableBounds regs base jump_index
    -- Get range for the index.
  | let abs_value = transferValue regs jump_index
  , StridedInterval index_interval  <- abs_value
    -- Check that relevant interval is completely contained within a read-only
    -- read only range in the memory.
  , SI.StridedInterval _ index_base index_range index_stride <-
        debug DCFG "getJumpTable3" $ index_interval
  , index_end <- index_base + (index_range + 1) * index_stride
  , rangeInReadonlySegment base (8 * fromInteger index_end) =
    -- Get the addresses associated.
    debug DCFG ("Fixed table " ++ show base ++ " [" ++ shows jump_index "]") $
      Just $! fromInteger index_end
getJumpTableBounds _ _ _ = Nothing

-- | This explores a block that ends with a fetch and execute.
fetchAndExecute :: forall arch ids
                .  ( RegisterInfo (ArchReg arch)
                   , ArchConstraint arch ids
                   , PrettyCFGConstraints arch
                   , MemWidth (ArchAddrWidth arch)
                   )
                => Block arch ids
                -> AbsProcessorState (ArchReg arch) ids
                   -- ^ Registers at this block after statements executed
                -> RegState (ArchReg arch) (Value arch ids)
                -> CFGM arch ids ()
fetchAndExecute b regs' s' = do
  let lbl = blockLabel b
  let src = labelAddr lbl
  mem <- gets memory :: CFGM arch ids (Memory (ArchAddrWidth arch))
  arch_info <- gets archInfo
  -- See if next statement appears to end with a call.
  -- We define calls as statements that end with a write that
  -- stores the pc to an address.
  case () of
    -- The last statement was a call.
    -- Note that in some cases the call is known not to return, and thus
    -- this code will never jump to the return value.
    _ | Just (prev_stmts, ret) <- identifyCall mem (blockStmts b) s' -> do
        Fold.mapM_ (recordWriteStmt src regs') prev_stmts
        let abst = finalAbsBlockState regs' s'
        seq abst $ do
        -- Merge caller return information
        mergeIntraJump lbl (archPostCallAbsState arch_info abst ret) ret
        -- Look for new ips.
        let addrs = concretizeAbsCodePointers mem (abst^.absRegState^.curIP)
        mapM_ (markAddrAsFunction (CallTarget src)) addrs
    -- This block ends with a return.
      | Just _ <- identifyReturn s' (callStackDelta arch_info) -> do
        mapM_ (recordWriteStmt src regs') (blockStmts b)

        let ip_val = s'^.boundValue ip_reg
        case transferValue regs' ip_val of
              ReturnAddr -> return ()
              -- The return_val is bad.
              -- This could indicate an imprecision in analysis or that the
              -- function will never return, and hence never was provided
              -- with an address to return to.
              rv ->
                debug DCFG ("return_val is bad at " ++ show lbl ++ ": " ++ show rv) $
                  return ()
      -- Jump to concrete offset.
      | Just tgt_addr <- asLiteralAddr mem (s'^.boundValue ip_reg) -> do
          let abst = finalAbsBlockState regs' s'
          seq abst $ do
          -- Try to check for a tail call.
          this_fn <- gets $ getFunctionEntryPoint src
          tgt_fn  <- gets $ getFunctionEntryPoint tgt_addr
          -- When the jump appears to go to another function, this could be a tail
          -- call or it could be dead code.
          if (this_fn /= tgt_fn) then do
            -- Check that the current stack height is correct so that a
            -- tail call when go to the right place.
            -- TODO: Add check to ensure stack height is correct.
            debug DCFG ("Found jump to concrete address after function " ++ show tgt_fn ++ ".") $ do
            markAddrAsFunction (InterProcedureJump src) tgt_addr
            -- Check top of stack points to return value.
            let sp_val = s'^.boundValue sp_reg
            let ptrType = BVTypeRepr (addrWidthNatRepr (archAddrWidth arch_info))
            let ret_val = transferRHS arch_info regs' (ReadMem sp_val ptrType)
            case ret_val of
              ReturnAddr ->
                debug DCFG ("tail_ret_val is correct " ++ show lbl) $
                  return ()
              TopV ->
                debug DCFG ("tail_ret_val is top at " ++ show lbl) $
                  return ()
              rv ->
                -- The return_val is bad.
                -- This could indicate that the caller knows that the function does
                -- not return, and hence will not provide a reutrn value.
                debug DCFG ("tail_ret_val is bad at " ++ show lbl ++ ": " ++ show rv) $
                  return ()
           else do
              assert (segmentFlags (addrSegment tgt_addr) `Perm.hasPerm` Perm.execute) $ do
              -- Merge block state.
              let abst' = abst & setAbsIP tgt_addr
              mergeIntraJump lbl abst' tgt_addr

      -- Block ends with what looks like a jump table.
      | AssignedValue (Assignment _ (ReadMem ptr _))
          <- debug DCFG "try jump table" $ s'^.curIP
        -- Attempt to compute interval of addresses interval is over.
      , Just (base, jump_idx) <- matchJumpTable mem ptr -> do
            debug DCFG ("Found jump table at " ++ show lbl) $ do

            mapM_ (recordWriteStmt src regs') (blockStmts b)

            -- Try to compute jump table bounds
            read_end <-
              case getJumpTableBounds regs' base jump_idx of
                Just e -> pure e
                Nothing -> error $ "Could not compute jump bounds."

            let abst :: AbsBlockState (ArchReg arch)
                abst = finalAbsBlockState regs' s'
            seq abst $ do
            -- This function resolves jump table entries.
            -- It is a recursive function that has an index into the jump table.
            -- If the current index can be interpreted as a intra-procedural jump,
            -- then it will add that to the current procedure.
            -- This returns the last address read.
            let resolveJump :: [ArchSegmentedAddr arch]
                               -- /\ Addresses in jump table in reverse order
                            -> ArchAddr arch
                               -- /\ Current index
                            -> CFGM arch ids [ArchSegmentedAddr arch]
                resolveJump prev idx | idx == read_end = do
                  -- Stop jump table when we have reached computed bounds.
                  return (reverse prev)
                resolveJump prev idx = do
                  let read_addr = base & addrOffset +~ 8 * idx
                  interpState <- get
                  case readAddr mem LittleEndian read_addr of
                    Right tgt_addr
                      | Perm.isReadonly (segmentFlags (addrSegment read_addr))
                      , inSameFunction src tgt_addr interpState -> do
                        let flags = segmentFlags (addrSegment tgt_addr)
                        assert (flags `Perm.hasPerm` Perm.execute) $ do
                        let abst' = abst & setAbsIP tgt_addr
                        mergeIntraJump lbl abst' tgt_addr
                        resolveJump (tgt_addr:prev) (idx+1)
                    _ -> do
                      debug DCFG ("Stop jump table: " ++ show idx ++ " " ++ show read_end) $ do
                      return (reverse prev)
            read_addrs <- resolveJump [] 0
            let last_index = fromIntegral (length read_addrs)
            let last_addr = Just $! base & addrOffset +~ 8 * last_index
            globalDataMap %= Map.insert base (JumpTable $! last_addr)

          -- We have a jump that we do not understand.
          -- This could be a tail call.
      | otherwise -> debug DCFG "Uninterpretable jump" $ do
        mapM_ (recordWriteStmt src regs') (blockStmts b)
        let abst = finalAbsBlockState regs' s'
        -- Get potential addresses for next IP
        let addrs = concretizeAbsCodePointers mem (abst^.absRegState^.curIP)
        -- Mark entry points as the start of functions
        mapM_ (markAddrAsFunction (error "Uninterpretable jump reason"))  addrs

type DiscoveryConstraints arch
   = ( PrettyCFGConstraints arch
     , RegisterInfo (ArchReg arch)
     , HasRepr (ArchReg arch)  TypeRepr
     , MemWidth (ArchAddrWidth arch)
     )

tryLookupBlock :: String
               -> ArchSegmentedAddr arch
               -> Map Word64 (Block arch ids)
               -> ArchLabel arch
               -> Block arch ids
tryLookupBlock ctx base block_map lbl =
  if labelAddr lbl /= base then
    error $ "internal error: tryLookupBlock " ++ ctx ++ " given invalid addr " ++ show (labelAddr lbl)
  else
    case Map.lookup (labelIndex lbl) block_map of
      Nothing ->
        error $ "internal error: tryLookupBlock " ++ ctx ++ " " ++ show base
             ++ " given invalid index " ++ show (labelIndex lbl)
      Just b -> b

-- | This evalutes the statements in a block to expand the information known
-- about control flow targets of this block.
transferBlock :: DiscoveryConstraints arch
              => Map Word64 (Block arch ids)
                 -- ^ Map for this sequence of blocks.
                 -- We keep this map independent of the blocks entry in the DiscoveryInfo, as it may be
                 -- invalidated in tryDisassembleAddr.
              -> Block arch ids -- ^ Block to start from
              -> AbsProcessorState (ArchReg arch) ids
                 -- ^ Abstract state describing machine state when block is encountered.
              -> CFGM arch ids ()
transferBlock block_map b regs = do
  let lbl = blockLabel b
  let src = labelAddr lbl
  mem <- gets memory
  arch_info <- gets archInfo
  let regs' = transferStmts arch_info regs (blockStmts b)
  -- FIXME: we should propagate c back to the initial block, not just b
  case blockTerm b of
    Branch c lb rb -> do
      mapM_ (recordWriteStmt src regs') (blockStmts b)
      let l = tryLookupBlock "left branch" (labelAddr (blockLabel b))  block_map lb
      let l_regs = refineProcState c absTrue regs'
      let r = tryLookupBlock "right branch" (labelAddr (blockLabel b)) block_map rb
      let r_regs = refineProcState c absFalse regs'
      -- We re-transfer the stmts to propagate any changes from
      -- the above refineProcState.  This could be more efficient by
      -- tracking what (if anything) changed.  We also might
      -- need to keep going back and forth until we reach a
      -- fixpoint
      transferBlock block_map l (transferStmts arch_info l_regs (blockStmts b))
      transferBlock block_map r (transferStmts arch_info r_regs (blockStmts b))

    Syscall s' -> do
      mapM_ (recordWriteStmt src regs') (blockStmts b)
      let abst = finalAbsBlockState regs' s'
      let ips = concretizeAbsCodePointers mem (abst^.absRegState^.curIP)
      -- Merge system call result with possible next IPs.
      Fold.forM_ ips $ \addr -> do
        mergeIntraJump lbl (archPostSyscallAbsState arch_info abst addr)  addr

    FetchAndExecute s' -> do
      fetchAndExecute b regs' s'
    -- Do nothing when this block ends in a translation error.
    TranslateError _ _ ->
      pure ()

transfer :: DiscoveryConstraints arch
         => ArchSegmentedAddr arch
         -> CFGM arch ids ()
transfer addr = do
  mem <- gets memory

  mbr <- use $ blocks . at addr
  case mbr of
    Nothing -> error $ "getBlock called on block " ++ show addr ++ " we have not seen."

    Just br -> do
      case Map.lookup 0 (brBlocks br) of
        Just root -> do
          transferBlock (brBlocks br) root $
            initAbsProcessorState mem (brAbsInitState br)
        Nothing -> do
          error $ "getBlock given block with empty blocks list."

------------------------------------------------------------------------
-- Main loop

explore_frontier :: DiscoveryConstraints arch
                 => CFGM arch ids ()
explore_frontier = do
  st <- get
  case Map.minViewWithKey (st^.frontier) of
    Nothing ->
      -- If local block frontier is empty, then try function frontier.
      case Map.minViewWithKey (st^.function_frontier) of
        Nothing -> return ()
        Just ((addr,rsn), next_roots) -> do
          let high = Set.lookupGT addr (st^.functionEntries)
              st' = st & function_frontier .~ next_roots
                       & frontier .~ Map.singleton addr rsn
                         -- Delete any entries we previously discovered for function.
                       & reverseEdges    %~ deleteMapRange (Just addr) high
                       & blocks          %~ deleteMapRange (Just addr) high
          put st'
          explore_frontier

    Just ((addr,_rsn), next_roots) -> do
      put $ st & frontier .~ next_roots
      transfer addr
      explore_frontier

-- | This returns true if the address is writable and value, and points to code.
memIsDataCodePointer :: Memory w -> SegmentedAddr w -> SegmentedAddr w -> Bool
memIsDataCodePointer _ a v
  =  segmentFlags (addrSegment v) `Perm.hasPerm` Perm.execute
  && segmentFlags (addrSegment a) `Perm.hasPerm` Perm.write

-- | Construct a discovery info by starting with exploring from a given set of
-- function entry points.
cfgFromAddrs :: forall arch
             .  DiscoveryConstraints arch
             => ArchitectureInfo arch
                -- ^ Architecture-specific information needed for doing control-flow exploration.
             -> Memory (ArchAddrWidth arch)
                -- ^ Memory to use when decoding instructions.
             -> Map (ArchSegmentedAddr arch) BS.ByteString
                -- ^ Names for (some) function entry points
             -> [ArchSegmentedAddr arch]
                -- ^ Initial function entry points.
             -> [(ArchSegmentedAddr arch, ArchSegmentedAddr arch)]
                -- ^ Function entry points in memory to be explored
                -- after exploring function entry points.
                --
                -- Each entry contains an address and the value stored in it.
             -> Some (DiscoveryInfo arch)
cfgFromAddrs arch_info mem symbols init_addrs mem_words =
  runCFGM arch_info mem symbols $ do
    -- Set abstract state for initial functions
    mapM_ (markAddrAsFunction InitAddr) init_addrs
    explore_frontier
    -- Add in code pointers from memory.
    let notAlreadyFunction s a v
            | Set.member v (s^.functionEntries) = False
            | otherwise = debug DCFG msg True
          where msg | Map.member v (s^.blocks) =
                        "Identified function entry "
                        ++ show v ++ " due to global store at " ++ show a ++ "."
                    | otherwise =
                        "Found function entry from memory" ++ show v ++ " at " ++ show a ++ "."
    s <- get
    let mem_addrs =
          filter (uncurry (notAlreadyFunction s)) $
          filter (uncurry (memIsDataCodePointer mem)) $
          mem_words
    mapM_ (\(src,val) -> markAddrAsFunction (CodePointerInMem src) val) mem_addrs
    explore_frontier
