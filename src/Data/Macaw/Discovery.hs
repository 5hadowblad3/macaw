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
       , State.memory
       , State.exploredFunctions
       , State.symbolNames
       , State.ppDiscoveryStateBlocks
       , cfgFromAddrs
       , markAddrsAsFunction
       , analyzeFunction
       , exploreMemPointers
       , analyzeDiscoveredFunctions
         -- * DiscoveryFunInfo
       , State.DiscoveryFunInfo
       , State.discoveredFunAddr
       , State.discoveredFunName
       , State.parsedBlocks
         -- * SymbolAddrMap
       , State.SymbolAddrMap
       , State.symbolAddrMap
       , State.symbolAddrs
       ) where

import           Control.Exception
import           Control.Lens
import           Control.Monad.ST
import           Control.Monad.State.Strict
import           Data.Foldable
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Parameterized.Classes
import           Data.Parameterized.Nonce
import           Data.Parameterized.Some
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Vector as V
import           Data.Word

import           Debug.Trace

import           Data.Macaw.AbsDomain.AbsState
import qualified Data.Macaw.AbsDomain.JumpBounds as Jmp
import           Data.Macaw.AbsDomain.Refine
import qualified Data.Macaw.AbsDomain.StridedInterval as SI
import           Data.Macaw.Architecture.Info
import           Data.Macaw.CFG
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

{-
printAddrBacktrace :: Map (ArchSegmentedAddr arch) (FoundAddr arch)
                   -> ArchSegmentedAddr arch
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
    InterProcedureJump src -> pp ("Reference from external address " ++ show src ++ ".") : prev src

-- | Return true if this address was added because of the contents of a global address
-- in memory initially.
--
-- This heuristic is not very accurate, so we avoid printing errors when it leads to
-- issues.
cameFromUnsoundReason :: Map (ArchSegmentedAddr arch) (FoundAddr arch)
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
    InterProcedureJump src -> prev src
-}

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
-- DiscoveryState utilities

-- | Mark a escaped code pointer as a function entry.
markAddrAsFunction :: CodeAddrReason (ArchAddrWidth arch)
                      -- ^ Information about why the code address was discovered
                      --
                      -- Used for debugging
                   -> ArchSegmentedAddr arch
                   -> DiscoveryState arch
                   -> DiscoveryState arch
markAddrAsFunction rsn addr s
  | Map.member addr (s^.funInfo) = s
  | otherwise = s & funInfo           %~ Map.insert addr Nothing
                  & unexploredFunctions %~ (:) (addr, rsn)

-- | Mark a list of addresses as function entries with the same reason.
markAddrsAsFunction :: CodeAddrReason (ArchAddrWidth arch)
                    -> [ArchSegmentedAddr arch]
                    -> DiscoveryState arch
                    -> DiscoveryState arch
markAddrsAsFunction rsn addrs s0 = foldl' (\s a -> markAddrAsFunction rsn a s) s0 addrs

------------------------------------------------------------------------
-- FunState

-- | The state for the function explroation monad
data FunState arch ids
   = FunState { funNonceGen  :: !(NonceGenerator (ST ids) ids)
              , curFunAddr   :: !(ArchSegmentedAddr arch)
              , _curFunCtx   :: !(DiscoveryState arch)
                -- ^ Discovery info
              , _curFunInfo  :: !(DiscoveryFunInfo arch ids)
                -- ^ Information about current function we are working on
              , _frontier    :: !(Set (ArchSegmentedAddr arch))
                -- ^ Addresses to explore next.
              }

-- | Discovery info
curFunCtx :: Simple Lens (FunState arch ids)  (DiscoveryState arch)
curFunCtx = lens _curFunCtx (\s v -> s { _curFunCtx = v })

-- | Information about current function we are working on
curFunInfo :: Simple Lens (FunState arch ids)  (DiscoveryFunInfo arch ids)
curFunInfo = lens _curFunInfo (\s v -> s { _curFunInfo = v })

-- | Set of addresses to explore next.
--
-- This is a map so that we can associate a reason why a code address
-- was added to the frontier.
frontier :: Simple Lens (FunState arch ids)  (Set (ArchSegmentedAddr arch))
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
mergeIntraJump  :: ArchSegmentedAddr arch
                  -- ^ Source label that we are jumping from.
                -> AbsBlockState (ArchReg arch)
                   -- ^ Block state after executing instructions.
                -> ArchSegmentedAddr arch
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
  s0 <- use curFunInfo
  case Map.lookup tgt (s0^.foundAddrs) of
    -- We have seen this block before, so need to join and see if
    -- the results is changed.
    Just old_info -> do
      case joinD (foundAbstractState old_info) ab of
        Nothing  -> return ()
        Just new -> do
          let new_info = old_info { foundAbstractState = new }
          curFunInfo . foundAddrs   %= Map.insert tgt new_info
          curFunInfo . reverseEdges %= Map.insertWith Set.union tgt (Set.singleton src)
          frontier %= Set.insert tgt
    -- We haven't seen this block before
    Nothing -> do
      curFunInfo . reverseEdges %= Map.insertWith Set.union tgt (Set.singleton src)
      frontier     %= Set.insert tgt
      let found_info = FoundAddr { foundReason = rsn
                                 , foundAbstractState = ab
                                 }
      curFunInfo . foundAddrs %= Map.insert tgt found_info

-------------------------------------------------------------------------------
-- Jump table bounds

-- See if expression matches form expected by jump tables
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
  , mul == toInteger (addrSize (memAddrWidth mem))
  , Perm.isReadonly (segmentFlags (addrSegment base)) = do
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
                   -> ArchSegmentedAddr a -- ^ Base
                   -> BVValue a ids (ArchAddrWidth a) -- ^ Index in jump table
                   -> Either (JumpTableBoundsError a ids) (ArchAddr a)
                   -- ^ One past last index in jump table or nothing
getJumpTableBounds info regs base jump_index = withArchConstraints info $
  case transferValue regs jump_index of
    StridedInterval (SI.StridedInterval _ index_base index_range index_stride) -> do
      let index_end = index_base + (index_range + 1) * index_stride
      if rangeInReadonlySegment base (jumpTableEntrySize info * fromInteger index_end) then
        case Jmp.unsignedUpperBound (regs^.indexBounds) jump_index of
          Right (Jmp.IntegerUpperBound bnd) | bnd == index_range -> Right $! fromInteger index_end
          Right bnd -> Left (UpperBoundMismatch bnd index_range)
          Left  msg -> Left (CouldNotFindBound  msg jump_index)
       else
        error $ "Jump table range is not in readonly memory"
--    TopV -> Left UpperBoundUndefined
    abs_value -> Left (CouldNotInterpretAbsValue abs_value)


-------------------------------------------------------------------------------
-- identifyReturn

-- | This is designed to detect returns from the register state representation.
--
-- It pattern matches on a 'RegState' to detect if it read its instruction
-- pointer from an address that is 8 below the stack pointer.
--
-- Note that this assumes the stack decrements as values are pushed, so we will
-- need to fix this on other architectures.
identifyReturn :: RegConstraint (ArchReg arch)
               => RegState (ArchReg arch) (Value arch ids)
               -> Integer
                  -- ^ How stack pointer moves when a call is made
               -> Maybe (Assignment arch ids (BVType (ArchAddrWidth arch)))
identifyReturn s stack_adj = do
  let next_ip = s^.boundValue ip_reg
      next_sp = s^.boundValue sp_reg
  case next_ip of
    AssignedValue asgn@(Assignment _ (ReadMem ip_addr _))
      | let (ip_base, ip_off) = asBaseOffset ip_addr
      , let (sp_base, sp_off) = asBaseOffset next_sp
      , (ip_base, ip_off) == (sp_base, sp_off + stack_adj) -> Just asgn
    _ -> Nothing


------------------------------------------------------------------------
--

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
  ParseState { _pblockMap :: !(Map Word64 (ParsedBlock arch ids))
               -- ^ Block m ap
             , _writtenCodeAddrs :: ![ArchSegmentedAddr arch]
               -- ^ Addresses marked executable that were written to memory.
             , _intraJumpTargets ::
                 ![(ArchSegmentedAddr arch, AbsBlockState (ArchReg arch))]
             , _newFunctionAddrs :: ![ArchSegmentedAddr arch]
             }

pblockMap :: Simple Lens (ParseState arch ids) (Map Word64 (ParsedBlock arch ids))
pblockMap = lens _pblockMap (\s v -> s { _pblockMap = v })

writtenCodeAddrs :: Simple Lens (ParseState arch ids) [ArchSegmentedAddr arch]
writtenCodeAddrs = lens _writtenCodeAddrs (\s v -> s { _writtenCodeAddrs = v })

intraJumpTargets :: Simple Lens (ParseState arch ids) [(ArchSegmentedAddr arch, AbsBlockState (ArchReg arch))]
intraJumpTargets = lens _intraJumpTargets (\s v -> s { _intraJumpTargets = v })

newFunctionAddrs :: Simple Lens (ParseState arch ids) [ArchSegmentedAddr arch]
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
             -> Maybe (Seq (Stmt a ids), ArchSegmentedAddr a)
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
              , Just val_a <- asLiteralAddr mem val
                -- Check if segment of address is marked as executable.
              , Perm.isExecutable (segmentFlags (addrSegment val_a)) ->
                Just (prev Seq.>< after, val_a)
                -- Stop if we hit any architecture specific instructions prior to
                -- identifying return address since they may have side effects.
              | ExecArchStmt _ <- stmt -> Nothing
                -- Otherwise skip over this instruction.
              | otherwise -> go prev (stmt Seq.<| after)

------------------------------------------------------------------------
-- ParseContext

data ParseContext arch ids = ParseContext { pctxMemory   :: !(Memory (ArchAddrWidth arch))
                                          , pctxArchInfo :: !(ArchitectureInfo arch)
                                          , pctxFunAddr  :: !(ArchSegmentedAddr arch)
                                            -- ^ Address of function this block is being parsed as
                                          , pctxAddr     :: !(ArchSegmentedAddr arch)
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
                     -> ArchLabel arch
                     -> [Stmt arch ids]
                     -> AbsProcessorState (ArchReg arch) ids
                     -- ^ Registers at this block after statements executed
                     -> RegState (ArchReg arch) (Value arch ids)
                     -> State (ParseState arch ids) (ParsedBlock arch ids)
parseFetchAndExecute ctx lbl stmts regs s' = do
  let src = labelAddr lbl
  let lbl_idx = labelIndex lbl
  let mem = pctxMemory ctx
  let arch_info = pctxArchInfo ctx
  withArchConstraints arch_info $ do
  -- See if next statement appears to end with a call.
  -- We define calls as statements that end with a write that
  -- stores the pc to an address.
  let regs' = absEvalStmts arch_info regs stmts
  case () of
    -- The last statement was a call.
    -- Note that in some cases the call is known not to return, and thus
    -- this code will never jump to the return value.
    _ | Just (prev_stmts, ret) <- identifyCall mem stmts s' -> do
        mapM_ (recordWriteStmt arch_info mem regs') prev_stmts
        let abst = finalAbsBlockState regs' s'
        seq abst $ do
        -- Merge caller return information
        intraJumpTargets %= ((ret, archPostCallAbsState arch_info abst ret):)
        -- Look for new ips.
        let addrs = concretizeAbsCodePointers mem (abst^.absRegState^.curIP)
        newFunctionAddrs %= (++ addrs)
        pure ParsedBlock { pblockLabel = lbl_idx
                         , pblockStmts = toList prev_stmts
                         , pblockState = regs'
                         , pblockTerm  = ParsedCall s' (Just ret)
                         }

    -- This block ends with a return.
      | Just asgn' <- identifyReturn s' (callStackDelta arch_info) -> do

        let isRetLoad s =
              case s of
                AssignStmt asgn
                  | Just Refl <- testEquality (assignId asgn) (assignId  asgn') -> True
                _ -> False
            nonret_stmts = filter (not . isRetLoad) stmts

        mapM_ (recordWriteStmt arch_info mem regs') nonret_stmts

        let ip_val = s'^.boundValue ip_reg
        case transferValue regs' ip_val of
          ReturnAddr -> return ()
          -- The return_val is bad.
          -- This could indicate an imprecision in analysis or maybe unreachable/bad code.
          rv ->
            debug DCFG ("return_val is bad at " ++ show lbl ++ ": " ++ show rv) $
                  return ()
        pure ParsedBlock { pblockLabel = lbl_idx
                         , pblockStmts = nonret_stmts
                         , pblockState = regs'
                         , pblockTerm = ParsedReturn s'
                         }

      -- Jump to concrete offset.
      --
      -- Note, we disallow jumps back to function entry point thus forcing them to be treated
      -- as tail calls or unclassified if the stack has changed size.
      | Just tgt_addr <- asLiteralAddr mem (s'^.boundValue ip_reg)
      , tgt_addr /= pctxFunAddr ctx -> do
         assert (segmentFlags (addrSegment tgt_addr) `Perm.hasPerm` Perm.execute) $ do
         mapM_ (recordWriteStmt arch_info mem regs') stmts
         -- Merge block state and add intra jump target.
         let abst = finalAbsBlockState regs' s'
         let abst' = abst & setAbsIP tgt_addr
         intraJumpTargets %= ((tgt_addr, abst'):)
         pure ParsedBlock { pblockLabel = lbl_idx
                          , pblockStmts = stmts
                          , pblockState = regs'
                          , pblockTerm  = ParsedJump s' tgt_addr
                          }
      -- Block ends with what looks like a jump table.
      | AssignedValue (Assignment _ (ReadMem ptr _)) <- debug DCFG "try jump table" $ s'^.curIP
        -- Attempt to compute interval of addresses interval is over.
      , Just (base, jump_idx) <- matchJumpTable mem ptr ->
        case getJumpTableBounds arch_info regs' base jump_idx of
          Left err ->
            trace (show src ++ ": Could not compute bounds: " ++ showJumpTableBoundsError err) $ do
            mapM_ (recordWriteStmt arch_info mem regs') stmts
            pure ParsedBlock { pblockLabel = lbl_idx
                             , pblockStmts = stmts
                             , pblockState = regs'
                             , pblockTerm  = ClassifyFailure s'
                             }
          Right read_end -> do
            mapM_ (recordWriteStmt arch_info mem regs') stmts

            -- Try to compute jump table bounds

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
                            -> State (ParseState arch ids) [ArchSegmentedAddr arch]
                resolveJump prev idx | idx == read_end = do
                  -- Stop jump table when we have reached computed bounds.
                  return (reverse prev)
                resolveJump prev idx = do
                  let read_addr = base & addrOffset +~ 8 * idx
                  case readAddr mem (archEndianness arch_info) read_addr of
                      Right tgt_addr
                        | Perm.isReadonly (segmentFlags (addrSegment read_addr)) -> do
                          let flags = segmentFlags (addrSegment tgt_addr)
                          assert (flags `Perm.hasPerm` Perm.execute) $ do
                          let abst' = abst & setAbsIP tgt_addr
                          intraJumpTargets %= ((tgt_addr, abst'):)
                          resolveJump (tgt_addr:prev) (idx+1)
                      _ -> do
                        debug DCFG ("Stop jump table: " ++ show idx ++ " " ++ show read_end) $ do
                          return (reverse prev)
            read_addrs <- resolveJump [] 0
            pure ParsedBlock { pblockLabel = lbl_idx
                             , pblockStmts = stmts
                             , pblockState = regs'
                             , pblockTerm = ParsedLookupTable s' jump_idx (V.fromList read_addrs)
                             }

      -- Check for tail call (anything where we are right at stack height
      | ptrType    <- addrMemRepr arch_info
      , sp_val     <-  s'^.boundValue sp_reg
      , ReturnAddr <- absEvalReadMem regs' sp_val ptrType -> do

        mapM_ (recordWriteStmt arch_info mem regs') stmts

        -- Compute fina lstate
        let abst = finalAbsBlockState regs' s'
        seq abst $ do

        -- Look for new instruction pointers
        let addrs = concretizeAbsCodePointers mem (abst^.absRegState^.curIP)
        newFunctionAddrs %= (++ addrs)


        pure ParsedBlock { pblockLabel = lbl_idx
                         , pblockStmts = stmts
                         , pblockState = regs'
                         , pblockTerm  = ParsedCall s' Nothing
                         }

      -- Block that ends with some unknown
      | otherwise -> do
          trace ("Could not classify " ++ show lbl) $ do
          mapM_ (recordWriteStmt arch_info mem regs') stmts
          pure ParsedBlock { pblockLabel = lbl_idx
                           , pblockStmts = stmts
                           , pblockState = regs'
                           , pblockTerm  = ClassifyFailure s'
                           }

-- | This evalutes the statements in a block to expand the information known
-- about control flow targets of this block.
parseBlocks :: ParseContext arch ids
               -- ^ Context for parsing blocks.
            -> [(Block arch ids, AbsProcessorState (ArchReg arch) ids)]
               -- ^ Queue of blocks to travese
            -> State (ParseState arch ids) ()
parseBlocks _ct [] = pure ()
parseBlocks ctx ((b,regs):rest) = do
  let mem       = pctxMemory ctx
  let arch_info = pctxArchInfo ctx
  withArchConstraints arch_info $ do
  let lbl = blockLabel b
  -- Assert we are still in source block.
  assert (pctxAddr ctx == labelAddr lbl) $ do
  let idx = labelIndex lbl
  let src = pctxAddr ctx
  let block_map = pctxBlockMap ctx
  -- FIXME: we should propagate c back to the initial block, not just b
  case blockTerm b of
    Branch c lb rb -> do
      let regs' = absEvalStmts arch_info regs (blockStmts b)
      mapM_ (recordWriteStmt arch_info mem regs') (blockStmts b)

      let l = tryLookupBlock "left branch"  src block_map lb
      let l_regs = refineProcStateBounds c True $ refineProcState c absTrue regs'
      let r = tryLookupBlock "right branch" src block_map rb
      let r_regs = refineProcStateBounds c False $ refineProcState c absFalse regs'
      -- We re-transfer the stmts to propagate any changes from
      -- the above refineProcState.  This could be more efficient by
      -- tracking what (if anything) changed.  We also might
      -- need to keep going back and forth until we reach a
      -- fixpoint
      let l_regs' = absEvalStmts arch_info l_regs (blockStmts b)
      let r_regs' = absEvalStmts arch_info r_regs (blockStmts b)


      let pb = ParsedBlock { pblockLabel = idx
                           , pblockStmts = blockStmts b
                           , pblockState = regs'
                           , pblockTerm  = ParsedBranch c (labelIndex lb) (labelIndex rb)
                           }
      pblockMap %= Map.insert idx pb

      parseBlocks ctx ((l, l_regs'):(r, r_regs'):rest)

    Syscall s' -> do
      let regs' = absEvalStmts arch_info regs (blockStmts b)
      mapM_ (recordWriteStmt arch_info mem regs') (blockStmts b)
      let abst = finalAbsBlockState regs' s'
      case concretizeAbsCodePointers mem (abst^.absRegState^.curIP) of
        [] -> error "Could not identify concrete system call address"
        [addr] -> do
          -- Merge system call result with possible next IPs.
          let post = archPostSyscallAbsState arch_info abst addr

          intraJumpTargets %= ((addr, post):)
          let pb = ParsedBlock { pblockLabel = idx
                               , pblockStmts = blockStmts b
                               , pblockState = regs'
                               , pblockTerm  = ParsedSyscall s' addr
                               }
          pblockMap %= Map.insert idx pb
          parseBlocks ctx rest
        _ -> error "Multiple system call addresses."


    FetchAndExecute s' -> do
      pb <- parseFetchAndExecute ctx (blockLabel b) (blockStmts b) regs s'
      pblockMap %= Map.insert idx pb
      parseBlocks ctx rest

    -- Do nothing when this block ends in a translation error.
    TranslateError _ msg -> do
      let regs' = absEvalStmts arch_info regs (blockStmts b)
      let pb = ParsedBlock { pblockLabel = idx
                           , pblockStmts = blockStmts b
                           , pblockState = regs'
                           , pblockTerm = ParsedTranslateError msg
                           }
      pblockMap %= Map.insert idx pb
      parseBlocks ctx rest

-- | This evalutes the statements in a block to expand the information known
-- about control flow targets of this block.
transferBlocks :: ArchAddr arch
                  -- ^ Size of the region these blocks cover.
               -> Map Word64 (Block arch ids)
                  -- ^ Map from labelIndex to associated block
               -> AbsProcessorState (ArchReg arch) ids
               -- ^ Abstract state describing machine state when block is encountered.
              -> FunM arch ids ()
transferBlocks sz bmap regs =
  case Map.lookup 0 bmap of
    Nothing -> do
      error $ "transferBlocks given empty blockRegion."
    Just b -> do
      funAddr <- gets curFunAddr
      s <- use curFunCtx
      let src = labelAddr (blockLabel b)
      let ctx = ParseContext { pctxMemory   = memory s
                             , pctxArchInfo = archInfo s
                             , pctxFunAddr  = funAddr
                             , pctxAddr     = src
                             , pctxBlockMap = bmap
                             }
      let ps0 = ParseState { _pblockMap = Map.empty
                           , _writtenCodeAddrs = []
                           , _intraJumpTargets = []
                           , _newFunctionAddrs = []
                           }
      let ps = execState (parseBlocks ctx [(b,regs)]) ps0
      let pb = ParsedBlockRegion { regionAddr = src
                                 , regionSize = sz
                                 , regionBlockMap = ps^.pblockMap
                                 }
      curFunInfo . parsedBlocks %= Map.insert src pb
      curFunCtx %= markAddrsAsFunction (InWrite src)    (ps^.writtenCodeAddrs)
                .  markAddrsAsFunction (CallTarget src) (ps^.newFunctionAddrs)
      mapM_ (\(addr, abs_state) -> mergeIntraJump src abs_state addr) (ps^.intraJumpTargets)

transfer :: ArchSegmentedAddr arch
         -> FunM arch ids ()
transfer addr = do
  mfinfo <- use $ curFunInfo . foundAddrs . at addr
  case mfinfo of
    Nothing -> error $ "getBlock called on unfound address " ++ show addr ++ "."
    Just finfo -> do
      info      <- uses curFunCtx archInfo
      nonce_gen <- gets funNonceGen
      mem       <- uses curFunCtx memory
      -- Attempt to disassemble block.
      -- Get memory so that we can decode from it.
      -- Returns true if we are not at the start of a block.
      -- This is used to stop the disassembler when we reach code
      -- that is part of a new block.
      prev_block_map <- use $ curFunInfo . parsedBlocks
      let not_at_block = (`Map.notMember` prev_block_map)
      let ab = foundAbstractState finfo
      (bs, sz, maybeError) <- liftST $ disassembleFn info nonce_gen mem not_at_block addr ab
      -- Build state for exploring this.
      case maybeError of
        Just e -> do
          trace ("Failed to disassemble " ++ show e) $ pure ()
        Nothing -> do
          pure ()

      withArchConstraints info $ do
      let block_map = Map.fromList [ (labelIndex (blockLabel b), b) | b <- bs ]
      transferBlocks sz block_map $ initAbsProcessorState mem (foundAbstractState finfo)

------------------------------------------------------------------------
-- Main loop

-- | Explore a specific function
explore_fun_loop :: FunM arch ids ()
explore_fun_loop = do
  st <- FunM get
  case Set.minView (st^.frontier) of
    Nothing -> return ()
    Just (addr, next_roots) -> do
      FunM $ put $ st & frontier .~ next_roots
      transfer addr
      explore_fun_loop

-- | This  the function at the given address
analyzeFunction :: ArchSegmentedAddr arch
               -- ^ The address to explore
            -> CodeAddrReason (ArchAddrWidth arch)
               -- ^ Reason to provide for why we are exploring function
               --
               -- This can be used to figure out why we decided a
               -- given address identified a code location.
            -> DiscoveryState arch
               -- ^ The current binary information.
            -> DiscoveryState arch
analyzeFunction addr rsn s = withGlobalSTNonceGenerator $ \gen -> do
  let info = archInfo s
  let mem  = memory s

  let initFunInfo = initDiscoveryFunInfo info mem (symbolNames s) addr rsn

  let fs0 = FunState { funNonceGen = gen
                     , curFunAddr  = addr
                     , _curFunCtx  = s
                     , _curFunInfo = initFunInfo
                     , _frontier   = Set.singleton addr
                     }
  fs <- execStateT (unFunM explore_fun_loop) fs0
  pure $ (fs^.curFunCtx) & funInfo %~ Map.insert addr (Just (Some (fs^.curFunInfo)))

-- | Analyze addresses that we have marked as functions, but not yet analyzed to
-- identify basic blocks, and discover new function candidates until we have
-- analyzed all function entry points.
analyzeDiscoveredFunctions :: DiscoveryState arch -> DiscoveryState arch
analyzeDiscoveredFunctions info =
  -- If local block frontier is empty, then try function frontier.
  case info^.unexploredFunctions of
    [] -> info
    (addr, rsn) : next_roots ->
      info & unexploredFunctions .~ next_roots
           & analyzeFunction addr rsn
           & analyzeDiscoveredFunctions

-- | This returns true if the address is writable and value is executable.
isDataCodePointer :: SegmentedAddr w -> SegmentedAddr w -> Bool
isDataCodePointer a v
  =  segmentFlags (addrSegment a) `Perm.hasPerm` Perm.write
  && segmentFlags (addrSegment v) `Perm.hasPerm` Perm.execute


addMemCodePointer :: (ArchSegmentedAddr arch, ArchSegmentedAddr arch)
                  -> DiscoveryState arch
                  -> DiscoveryState arch
addMemCodePointer (src,val) = markAddrAsFunction (CodePointerInMem src) val

exploreMemPointers :: [(ArchSegmentedAddr arch, ArchSegmentedAddr arch)]
                   -- ^ List of addresses and value pairs to use for
                   -- considering possible addresses.
                   -> DiscoveryState arch
                   -> DiscoveryState arch
exploreMemPointers mem_words info =
  flip execState info $ do
    let notAlreadyFunction s (_a, v) = not (Map.member v (s^.funInfo))
    let mem_addrs =
          filter (notAlreadyFunction info) $
          filter (uncurry isDataCodePointer) $
          mem_words
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
             -> [ArchSegmentedAddr arch]
                -- ^ Initial function entry points.
             -> [(ArchSegmentedAddr arch, ArchSegmentedAddr arch)]
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
