{-|
Copyright  : (c) Galois, Inc 2016
Maintainer : jhendrix@galois.com

This defines the main data structure for storing information learned from code
discovery.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
module Data.Macaw.Discovery.Info
  ( BlockRegion(..)
  , FoundAddr(..)
  , lookupBlock
  , GlobalDataInfo(..)
  , ParsedTermStmt(..)
  , ParsedBlock(..)
    -- * The interpreter state
  , DiscoveryInfo
  , emptyDiscoveryInfo
  , nonceGen
  , archInfo
  , memory
  , symbolNames
  , foundAddrs
  , blocks
  , functionEntries
  , reverseEdges
  , globalDataMap
  , tryGetStaticSyscallNo
  , classifyBlock
    -- * Frontier
  , CodeAddrReason(..)
  , frontier
  , function_frontier
    -- ** DiscoveryInfo utilities
  , getFunctionEntryPoint
  , inSameFunction
  , ArchConstraint
  , identifyCall
  , identifyReturn
  , asLiteralAddr
  )  where

import           Control.Lens
import           Control.Monad.ST
import qualified Data.ByteString as BS
import           Data.Foldable
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Parameterized.Classes
import           Data.Parameterized.Nonce
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Vector as V
import           Data.Word
import           Numeric (showHex)

import           Data.Macaw.AbsDomain.AbsState
import           Data.Macaw.Architecture.Info
import           Data.Macaw.CFG
import           Data.Macaw.Memory
import qualified Data.Macaw.Memory.Permissions as Perm
import           Data.Macaw.Types


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
-- BlockRegion

-- | A contiguous region of instructions in memory.
data BlockRegion arch ids
   = BlockRegion { brSize :: !(ArchAddr arch)
                   -- ^ The size of the region of memory covered by this.
                 , brBlocks :: !(Map Word64 (Block arch ids))
                   -- ^ Map from labelIndex to associated block.
                 }

------------------------------------------------------------------------
-- CodeAddrReason

-- | This describes the source of an address that was marked as containing code.
data CodeAddrReason w
   = InWrite !(SegmentedAddr w)
     -- ^ Exploring because the given block writes it to memory.
   | NextIP !(SegmentedAddr w)
     -- ^ Exploring because the given block jumps here.
   | CallTarget !(SegmentedAddr w)
     -- ^ Exploring because address terminates with a call that jumps here.
   | InitAddr
     -- ^ Identified as an entry point from initial information
   | CodePointerInMem !(SegmentedAddr w)
     -- ^ A code pointer that was stored at the given address.
   | SplitAt !(SegmentedAddr w)
     -- ^ Added because the address split this block after it had been disassembled.
   | InterProcedureJump !(SegmentedAddr w)
     -- ^ A jump from an address in another function.
  deriving (Show)

------------------------------------------------------------------------
-- GlobalDataInfo

data GlobalDataInfo w
     -- | A jump table that appears to end just before the given address.
   = JumpTable !(Maybe w)
     -- | A value that appears in the program text.
   | ReferencedValue

instance (Integral w, Show w) => Show (GlobalDataInfo w) where
  show (JumpTable Nothing) = "unbound jump table"
  show (JumpTable (Just w)) | w >= 0 = "jump table end " ++ showHex w ""
                            | otherwise = error "jump table with negative offset given"
  show ReferencedValue = "global addr"

------------------------------------------------------------------------
-- ParsedTermStmt

-- | This term statement is used to describe higher level expressions
-- of how block ending with a a FetchAndExecute statement should be
-- interpreted.
data ParsedTermStmt arch ids
   = ParsedCall !(RegState (ArchReg arch) (Value arch ids))
                !(Maybe (ArchSegmentedAddr arch))
    -- ^ A call with the current register values and location to return to or 'Nothing'  if this is a tail call.
   | ParsedJump !(RegState (ArchReg arch) (Value arch ids)) !(ArchSegmentedAddr arch)
     -- ^ A jump to an explicit address within a function.
   | ParsedLookupTable !(RegState (ArchReg arch) (Value arch ids))
                       !(BVValue arch ids (ArchAddrWidth arch))
                       !(V.Vector (ArchSegmentedAddr arch))
     -- ^ A lookup table that branches to one of a vector of addresses.
     --
     -- The registers store the registers, the value contains the index to jump
     -- to, and the possible addresses.
   | ParsedReturn !(RegState (ArchReg arch) (Value arch ids))
     -- ^ A return with the given registers.
   | ParsedBranch !(Value arch ids BoolType) !Word64 !Word64
     -- ^ A branch (i.e., BlockTerm is Branch)
   | ParsedSyscall !(RegState (ArchReg arch) (Value arch ids))
                   !(ArchSegmentedAddr arch)
     -- ^ A system call with the registers prior to call and given return address.
   | ParsedTranslateError !Text
     -- ^ An error occured in translating the block
   | ClassifyFailure !String
     -- ^ The classifier failed to identity the block.

deriving instance
  ( PrettyCFGConstraints arch
  , Show (ArchReg arch (BVType (ArchAddrWidth arch)))
  )
  => Show (ParsedTermStmt arch ids)

------------------------------------------------------------------------
-- ParsedBlock

data ParsedBlock arch ids
   = ParsedBlock { pblockLabel :: !Word64
                 , pblockStmts :: !([Stmt arch ids])
                 , pblockState :: !(AbsProcessorState (ArchReg arch) ids)
                   -- ^ State of processor prior to term statement.
                 , pblockTerm  :: !(ParsedTermStmt arch ids)
                 }

------------------------------------------------------------------------
-- DiscoveryInfo

-- | The state of the interpreter
data DiscoveryInfo arch ids
   = DiscoveryInfo { nonceGen    :: !(NonceGenerator (ST ids) ids)
                     -- ^ Generator for creating fresh ids.
                   , memory      :: !(Memory (ArchAddrWidth arch))
                     -- ^ The initial memory when disassembly started.
                   , symbolNames :: !(Map (ArchSegmentedAddr arch) BS.ByteString)
                     -- ^ The set of symbol names (not necessarily complete)
                   , archInfo    :: !(ArchitectureInfo arch)
                     -- ^ Architecture-specific information needed for discovery.
                   , _foundAddrs :: !(Map (ArchSegmentedAddr arch) (FoundAddr arch))
                     -- ^ Maps fopund address to the pre-state for that block.
                   , _blocks     :: !(Map (ArchSegmentedAddr arch) (BlockRegion arch ids))
                     -- ^ Maps an address to the code associated with that address.
                   , _functionEntries :: !(Set (ArchSegmentedAddr arch))
                      -- ^ Maps addresses that are marked as the start of a function
                   , _reverseEdges :: !(Map (ArchSegmentedAddr arch)
                                            (Set (ArchSegmentedAddr arch)))
                     -- ^ Maps each code address to the list of predecessors that
                     -- affected its abstract state.
                   , _globalDataMap :: !(Map (ArchSegmentedAddr arch)
                                             (GlobalDataInfo (ArchSegmentedAddr arch)))
                     -- ^ Maps each address that appears to be global data to information
                     -- inferred about it.
                   , _frontier :: !(Map (ArchSegmentedAddr arch)
                                        (CodeAddrReason (ArchAddrWidth arch)))
                     -- ^ Addresses to explore next.
                     --
                     -- This is a map so that we can associate a reason why a code
                     -- address was added to the frontier.
                   , _function_frontier :: !(Map (ArchSegmentedAddr arch)
                                                 (CodeAddrReason (ArchAddrWidth arch)))
                     -- ^ Set of functions to explore next.
                   }

-- | Empty interpreter state.
emptyDiscoveryInfo :: NonceGenerator (ST ids) ids
                   -> Memory (ArchAddrWidth arch)
                   -> Map (ArchSegmentedAddr arch) BS.ByteString
                   -> ArchitectureInfo arch
                      -- ^ architecture/OS specific information
                   -> DiscoveryInfo arch ids
emptyDiscoveryInfo ng mem symbols info = DiscoveryInfo
      { nonceGen           = ng
      , memory             = mem
      , symbolNames        = symbols
      , archInfo           = info
      , _foundAddrs        = Map.empty
      , _blocks            = Map.empty
      , _functionEntries   = Set.empty
      , _reverseEdges      = Map.empty
      , _globalDataMap     = Map.empty
      , _frontier          = Map.empty
      , _function_frontier = Map.empty
      }

foundAddrs :: Simple Lens (DiscoveryInfo arch ids) (Map (ArchSegmentedAddr arch) (FoundAddr arch))
foundAddrs = lens _foundAddrs (\s v -> s { _foundAddrs = v })

blocks :: Simple Lens (DiscoveryInfo arch ids)
                      (Map (ArchSegmentedAddr arch) (BlockRegion arch ids))
blocks = lens _blocks (\s v -> s { _blocks = v })

-- | Addresses that start each function.
functionEntries :: Simple Lens (DiscoveryInfo arch ids) (Set (ArchSegmentedAddr arch))
functionEntries = lens _functionEntries (\s v -> s { _functionEntries = v })

reverseEdges :: Simple Lens (DiscoveryInfo arch ids)
                            (Map (ArchSegmentedAddr arch) (Set (ArchSegmentedAddr arch)))
reverseEdges = lens _reverseEdges (\s v -> s { _reverseEdges = v })

-- | Map each jump table start to the address just after the end.
globalDataMap :: Simple Lens (DiscoveryInfo arch ids)
                             (Map (ArchSegmentedAddr arch)
                                  (GlobalDataInfo (ArchSegmentedAddr arch)))
globalDataMap = lens _globalDataMap (\s v -> s { _globalDataMap = v })

-- | Set of addresses to explore next.
--
-- This is a map so that we can associate a reason why a code address
-- was added to the frontier.
frontier :: Simple Lens (DiscoveryInfo arch ids)
                        (Map (ArchSegmentedAddr arch) (CodeAddrReason (ArchAddrWidth arch)))
frontier = lens _frontier (\s v -> s { _frontier = v })

-- | Set of functions to explore next.
function_frontier :: Simple Lens (DiscoveryInfo arch ids)
                                 (Map (ArchSegmentedAddr arch)
                                      (CodeAddrReason (ArchAddrWidth arch)))
function_frontier = lens _function_frontier (\s v -> s { _function_frontier = v })


-- | Does a simple lookup in the cfg at a given DecompiledBlock address.
lookupBlock :: DiscoveryInfo arch ids
            -> ArchLabel arch
            -> Maybe (Block arch ids)
lookupBlock info lbl = do
  br <- Map.lookup (labelAddr lbl) (info^.blocks)
  Map.lookup (labelIndex lbl) (brBlocks br)

------------------------------------------------------------------------
-- DiscoveryInfo utilities

-- | Returns the guess on the entry point of the given function.
--
-- Note. This code assumes that a block address is associated with at most one function.
getFunctionEntryPoint :: ArchSegmentedAddr a
                      -> DiscoveryInfo a ids
                      -> ArchSegmentedAddr a
getFunctionEntryPoint addr s = do
  case Set.lookupLE addr (s^.functionEntries) of
    Just a -> a
    Nothing -> error $ "Could not find address of " ++ show addr ++ "."

-- | Returns the guess on the entry point of the given function.
--
-- Note. This code assumes that a block address is associated with at most one function.
getFunctionEntryPoint' :: ArchSegmentedAddr a
                       -> DiscoveryInfo a ids
                       -> Maybe (ArchSegmentedAddr a)
getFunctionEntryPoint' addr s = Set.lookupLE addr (s^.functionEntries)

-- | Return true if the two addresses look like they are in the same
inSameFunction :: ArchSegmentedAddr a
               -> ArchSegmentedAddr a
               -> DiscoveryInfo a ids
               -> Bool
inSameFunction x y s = xf == yf
  where Just xf = Set.lookupLE x (s^.functionEntries)
        Just yf = Set.lookupLE y (s^.functionEntries)

-- | Constraint on architecture register values needed by code exploration.
type RegConstraint r = (OrdF r, HasRepr r TypeRepr, RegisterInfo r, ShowF r)

-- | Constraint on architecture so that we can do code exploration.
type ArchConstraint a ids = ( RegConstraint (ArchReg a)
                            )

-- | This returns a segmented address if the value can be interpreted as a literal memory
-- address, and returns nothing otherwise.
asLiteralAddr :: MemWidth (ArchAddrWidth arch)
              => Memory (ArchAddrWidth arch)
              -> BVValue arch ids (ArchAddrWidth arch)
              -> Maybe (ArchSegmentedAddr arch)
asLiteralAddr mem (BVValue _ val) =
  absoluteAddrSegment mem (fromInteger val)
asLiteralAddr _   (RelocatableValue _ a) = Just a
asLiteralAddr _ _ = Nothing

-- | Attempt to identify the write to a stack return address, returning
-- instructions prior to that write and return  values.
--
-- This can also return Nothing if the call is not supported.
identifyCall :: ( ArchConstraint a ids
                , MemWidth (ArchAddrWidth a)
                )
             => Memory (ArchAddrWidth a)
             -> [Stmt a ids]
             -> RegState (ArchReg a) (Value a ids)
             -> Maybe (Seq (Stmt a ids), ArchSegmentedAddr a)
identifyCall mem stmts0 s = go (Seq.fromList stmts0)
  where -- Get value of stack pointer
        next_sp = s^.boundValue sp_reg
        -- Recurse on statements.
        go stmts =
          case Seq.viewr stmts of
            Seq.EmptyR -> Nothing
            prev Seq.:> stmt
              -- Check for a call statement by determining if the last statement
              -- writes an executable address to the stack pointer.
              | WriteMem a val <- stmt
              , Just _ <- testEquality a next_sp
                -- Check this is the right length.
              , Just Refl <- testEquality (typeRepr next_sp) (typeRepr val)
                -- Check if value is a valid literal address
              , Just val_a <- asLiteralAddr mem val
                -- Check if segment of address is marked as executable.
              , Perm.isExecutable (segmentFlags (addrSegment val_a)) ->

                Just (prev, val_a)
                -- Stop if we hit any architecture specific instructions prior to
                -- identifying return address since they may have side effects.
              | ExecArchStmt _ <- stmt -> Nothing
                -- Otherwise skip over this instruction.
              | otherwise -> go prev

-- | This is designed to detect returns from the register state representation.
--
-- It pattern matches on a 'RegState' to detect if it read its instruction
-- pointer from an address that is 8 below the stack pointer.
--
-- Note that this assumes the stack decrements as values are pushed, so we will
-- need to fix this on other architectures.
identifyReturn :: ArchConstraint arch ids
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

-- | This identifies a jump table
--
-- A jump table consists of a contiguous sequence of jump targets laid out in
-- memory.  Each potential jump target is in the same function as the calling
-- function.
identifyJumpTable :: forall arch ids
                  .  MemWidth (ArchAddrWidth arch)
                  => DiscoveryInfo arch ids
                  -> ArchSegmentedAddr arch
                      -- ^ Address of enclosing function.
                  -> BVValue arch ids (ArchAddrWidth arch)
                     -- ^ The location we are jumping to
                     --
                     -- This is parsed to be of the form:
                     --   (mult * idx) + base
                     -- base is expected to be an integer.
                  -> Maybe ( BVValue arch ids (ArchAddrWidth arch)
                           , V.Vector (ArchSegmentedAddr arch)
                           )
identifyJumpTable s enclosingFun (AssignedValue (Assignment _ (ReadMem ptr _)))
    -- Turn the read address into base + offset.
   | Just (BVAdd _ offset base_val) <- valueAsApp ptr
   , Just base <- asLiteralAddr mem base_val
    -- Turn the offset into a multiple by an index.
   , Just (BVMul _ (BVValue _ mult) idx) <- valueAsApp offset
   , mult == toInteger (jumpTableEntrySize info)
    -- Find segment associated with base(if any)
    -- Check if it read only
    --
    -- The convention seems to be to store jump tables in read only memory.
  , Perm.isReadonly (segmentFlags (addrSegment base)) =
       Just (idx, V.unfoldr nextWord base)
  where
    info = archInfo s
    mem  = memory   s

    nextWord :: ArchSegmentedAddr arch
             -> Maybe (ArchSegmentedAddr arch, ArchSegmentedAddr arch)
    nextWord base
      | Right codePtr <- readAddr mem LittleEndian base
      , getFunctionEntryPoint' codePtr s == Just enclosingFun =
        Just (codePtr, base & addrOffset +~ jumpTableEntrySize info)
      | otherwise = Nothing
identifyJumpTable _ _ _ = Nothing

tryGetStaticSyscallNo :: ArchConstraint arch ids
                      => DiscoveryInfo arch ids
                         -- ^ Discovery information
                      -> ArchSegmentedAddr arch
                         -- ^ Address of this block
                      -> RegState (ArchReg arch) (Value arch ids)
                         -- ^ State of processor
                      -> Maybe Integer
tryGetStaticSyscallNo interp_state block_addr proc_state
  | BVValue _ call_no <- proc_state^.boundValue syscall_num_reg =
    Just call_no
  | Initial r <- proc_state^.boundValue syscall_num_reg
  , Just info <- interp_state^.foundAddrs^.at block_addr =
    asConcreteSingleton (foundAbstractState info^.absRegState^.boundValue r)
  | otherwise =
    Nothing

-- | Classifies the terminal statement in a block using discovered information.
classifyBlock :: forall arch ids
              .  (ArchConstraint arch ids, MemWidth (ArchAddrWidth arch))
              => Block arch ids
              -> DiscoveryInfo arch ids
              -> ([Stmt arch ids], ParsedTermStmt arch ids)
classifyBlock b interp_state = do
  let stmts = blockStmts b
      mem = memory interp_state

  case blockTerm b of
    TranslateError _ msg -> (stmts, ParsedTranslateError msg)
    Branch c x y
      | labelAddr x /= labelAddr (blockLabel b) -> error "Branch with bad child"
      | labelAddr y /= labelAddr (blockLabel b) -> error "Branch with bad child"
      | otherwise -> (stmts, ParsedBranch c (labelIndex x) (labelIndex y))
    FetchAndExecute proc_state
        -- The last statement was a call.
      | Just (prev_stmts, ret_addr) <- identifyCall mem stmts proc_state ->
        (toList prev_stmts, ParsedCall proc_state (Just ret_addr))

      -- Jump to concrete offset.
      | Just tgt_addr <- asLiteralAddr mem (proc_state^.boundValue ip_reg)
      , inSameFunction (labelAddr (blockLabel b)) tgt_addr interp_state ->
        (stmts, ParsedJump proc_state tgt_addr)

      -- Return
      | Just asgn <- identifyReturn proc_state (callStackDelta (archInfo interp_state)) ->
        let isRetLoad s =
              case s of
                AssignStmt asgn'
                  | Just Refl <- testEquality (assignId asgn) (assignId  asgn') -> True
                _ -> False
            nonret_stmts = filter (not . isRetLoad) stmts
        in (nonret_stmts, ParsedReturn proc_state)

        -- Jump table
      | let entry = getFunctionEntryPoint (labelAddr (blockLabel b)) interp_state
      , let cur_ip = proc_state^.boundValue ip_reg
      , Just (idx, nexts) <- identifyJumpTable interp_state entry cur_ip ->
          (stmts, ParsedLookupTable proc_state idx nexts)

      -- Finally, we just assume that this is a tail call through a pointer
      -- FIXME: probably unsound.
      | otherwise ->
        (stmts, ParsedCall proc_state Nothing)

    -- rax is concrete in the first case, so we don't need to propagate it etc.
    Syscall proc_state
      | Just next_addr <- asLiteralAddr mem (proc_state^.boundValue ip_reg) ->
        (stmts, ParsedSyscall proc_state next_addr)

      | otherwise -> (stmts, ClassifyFailure "System call with non-literal return address.")
