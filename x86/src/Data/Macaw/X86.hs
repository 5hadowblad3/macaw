{-
Copyright        : (c) Galois, Inc 2015-2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>

This defines the primitives needed to provide architecture info for
x86_64 programs.
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NondecreasingIndentation #-}
module Data.Macaw.X86
       ( x86_64_freeBSD_info
       , x86_64_linux_info
       , freeBSD_syscallPersonality
       , linux_syscallPersonality
         -- * Low level exports
       , ExploreLoc
       , rootLoc
       , disassembleBlock
       , X86TranslateError(..)
       , Data.Macaw.X86.ArchTypes.X86_64
       , Data.Macaw.X86.ArchTypes.X86PrimFn(..)
       , Data.Macaw.X86.ArchTypes.X86Stmt(..)
       , Data.Macaw.X86.ArchTypes.X86TermStmt(..)
       , Data.Macaw.X86.X86Reg.X86Reg(..)
       , Data.Macaw.X86.X86Reg.x86ArgumentRegs
       , Data.Macaw.X86.X86Reg.x86ResultRegs
       , Data.Macaw.X86.X86Reg.x86FloatArgumentRegs
       , Data.Macaw.X86.X86Reg.x86FloatResultRegs
       , Data.Macaw.X86.X86Reg.x86CalleeSavedRegs
       , pattern Data.Macaw.X86.X86Reg.RAX
       , x86DemandContext
       ) where

import           Control.Exception (assert)
import           Control.Lens
import           Control.Monad.Cont
import           Control.Monad.Except
import           Control.Monad.ST
import           Data.Foldable
import qualified Data.Map as Map
import           Data.Parameterized.Classes
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.NatRepr
import           Data.Parameterized.Nonce
import           Data.Parameterized.Some
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Flexdis86 as F
import           Text.PrettyPrint.ANSI.Leijen (Pretty(..), text)

import           Data.Macaw.AbsDomain.AbsState
       ( AbsBlockState
       , setAbsIP
       , absRegState
       , StackEntry(..)
       , concreteStackOffset
       , AbsValue(..)
       , top
       , stridedInterval
       , asConcreteSingleton
       , startAbsStack
       , hasMaximum
       , AbsProcessorState
       , transferValue
       , CallParams(..)
       , absEvalCall
       )
import qualified Data.Macaw.AbsDomain.StridedInterval as SI
import           Data.Macaw.Architecture.Info
import           Data.Macaw.CFG
import           Data.Macaw.CFG.DemandSet
import qualified Data.Macaw.Memory.Permissions as Perm
import           Data.Macaw.Types
  ( n8
  , HasRepr(..)
  )
import           Data.Macaw.X86.ArchTypes
import           Data.Macaw.X86.Flexdis
import           Data.Macaw.X86.Semantics (execInstruction)
import           Data.Macaw.X86.SyscallInfo
import           Data.Macaw.X86.SyscallInfo.FreeBSD as FreeBSD
import           Data.Macaw.X86.SyscallInfo.Linux as Linux
import           Data.Macaw.X86.X86Reg

import           Data.Macaw.X86.Generator

------------------------------------------------------------------------
-- ExploreLoc

-- | This represents the control-flow information needed to build basic blocks
-- for a code location.
data ExploreLoc
   = ExploreLoc { loc_ip      :: !(MemSegmentOff 64)
                  -- ^ IP address.
                , loc_x87_top :: !Int
                  -- ^ Top register of x87 stack
                , loc_df_flag :: !Bool
                  -- ^ Value of DF flag
                }
 deriving (Eq, Ord)

instance Pretty ExploreLoc where
  pretty loc = text $ show (loc_ip loc)

rootLoc :: MemSegmentOff 64 -> ExploreLoc
rootLoc ip = ExploreLoc { loc_ip      = ip
                        , loc_x87_top = 7
                        , loc_df_flag = False
                        }

initX86State :: ExploreLoc -- ^ Location to explore from.
             -> RegState X86Reg (Value X86_64 ids)
initX86State loc = mkRegState Initial
                 & curIP     .~ RelocatableValue Addr64 (relativeSegmentAddr (loc_ip loc))
                 & boundValue X87_TopReg .~ mkLit knownNat (toInteger (loc_x87_top loc))
                 & boundValue DF         .~ BoolValue (loc_df_flag loc)

------------------------------------------------------------------------
-- Location

-- | Signal an error from the initial address.
initError :: ExploreLoc -- ^ Location to explore from.
          -> X86TranslateError 64
          -> ST st_s (Block X86_64 ids, MemWord 64, Maybe (X86TranslateError 64))
initError loc err = do
  let addr = loc_ip loc
  let s = initX86State loc
  let b = Block { blockLabel = 0
                , blockStmts = []
                , blockTerm  = TranslateError s (Text.pack (show err))
                }
  return (b, msegOffset addr, Just err)

-- | Returns from the block translator with the preblock built so far
-- and the current address
returnWithError :: PreBlock ids
                 -> MemSegmentOff 64
                 -> X86TranslateError 64
                 -> ST st_s (Block X86_64 ids, MemWord 64, Maybe (X86TranslateError 64))
returnWithError pblock curIPAddr err = do
  let b = Block { blockLabel = pBlockIndex pblock
                , blockStmts = toList (pblock^.pBlockStmts)
                , blockTerm  = TranslateError (pblock^.pBlockState) (Text.pack (show err))
                }
  return (b, msegOffset curIPAddr, Just err)

-- | Translate block, returning blocks read, ending
-- PC, and an optional error.  and ending PC.
disassembleBlockImpl :: forall st_s ids
                     .  NonceGenerator (ST st_s) ids
                        -- ^ Generator for new assign ids
                     -> PreBlock ids
                        -- ^ Block information built up so far.
                     -> MemSegmentOff 64
                        -- ^ Address of next instruction to translate
                     -> MemWord 64
                         -- ^ Maximum offset for this addr.
                     -> [SegmentRange 64]
                        -- ^ List of contents to read next.
                     -> ST st_s (Block X86_64 ids, MemWord 64, Maybe (X86TranslateError 64))
disassembleBlockImpl nonceGen pblock curIPAddr max_offset contents = do
  case readInstruction curIPAddr contents of
    Left msg -> do
      returnWithError pblock curIPAddr msg
    Right (i, next_ip_off, nextContents) -> do
      let seg = msegSegment curIPAddr
      let off = msegOffset curIPAddr
      -- Get size of instruction
      let instSize :: Int
          instSize = fromIntegral (next_ip_off - off)
      let next_ip :: MemAddr 64
          next_ip = relativeAddr seg next_ip_off
      let next_ip_val :: BVValue X86_64 ids 64
          next_ip_val = RelocatableValue Addr64 next_ip
      case execInstruction (ValueExpr next_ip_val) i of
        Nothing -> do
          returnWithError pblock curIPAddr (UnsupportedInstruction curIPAddr i)
        Just exec -> do
          let gs = GenState { assignIdGen = nonceGen
                            , _blockState = pblock
                            , genInitPCAddr = curIPAddr
                            , genInstructionSize = instSize
                            , avxMode = False
                            , _genRegUpdates = MapF.empty
                            }
          gsr <-
            runExceptT $ runX86Generator gs $ do
              let line = show curIPAddr ++ ": " ++ show (F.ppInstruction i)
              addStmt (Comment (Text.pack line))
              exec
          case gsr of
            Left msg -> do
              returnWithError pblock curIPAddr (ExecInstructionError curIPAddr i msg)
            Right res -> do
              case res of
                -- If IP after interpretation is the next_ip, there are no blocks, and we
                -- haven't crossed max_offset, then keep running.
                UnfinishedGenResult p_b
                  | RelocatableValue _ v <- p_b^.(pBlockState . curIP)
                  , v == next_ip
                    -- Check to see if we should continue
                  , next_ip_off < max_offset
                  , Just next_ip_segaddr <- resolveSegmentOff seg next_ip_off ->
                    disassembleBlockImpl nonceGen p_b next_ip_segaddr max_offset nextContents
                _ ->
                  return (finishGenResult res, next_ip_off, Nothing)

-- | Disassemble block, returning either an error, or a list of blocks
-- and ending PC.
disassembleBlock :: forall s
                 .  NonceGenerator (ST s) s
                 -> ExploreLoc
                 -> MemWord 64
                    -- ^ Maximum number of bytes in ths block.
                 -> ST s (Block X86_64 s, MemWord 64, Maybe (X86TranslateError 64))
disassembleBlock nonce_gen loc max_size = do
  let addr = loc_ip loc
  let sz = msegOffset addr + max_size
  (b, next_ip_off, maybeError) <-
    case contentsAfterSegmentOff addr of
      Left msg -> do
        initError loc (FlexdisMemoryError msg)
      Right contents -> do
        let pblock = emptyPreBlock (initX86State loc) 0
        disassembleBlockImpl nonce_gen pblock addr sz contents
  assert (next_ip_off > msegOffset addr) $ do
  let block_sz = next_ip_off - msegOffset addr
  pure (b, block_sz, maybeError)

-- | The abstract state for a function begining at a given address.
initialX86AbsState :: MemSegmentOff 64 -> AbsBlockState X86Reg
initialX86AbsState addr
  = top
  & setAbsIP addr
  & absRegState . boundValue sp_reg .~ concreteStackOffset (relativeSegmentAddr addr) 0
  -- x87 top register points to top of stack.
  & absRegState . boundValue X87_TopReg .~ FinSet (Set.singleton 7)
  -- Direction flag is initially zero.
  -- "The direction flag DF in the %rFLAGS register
  --- must be clear (set to “forward” direction) on function entry and
  --- return." (AMD64 ABI Draft 1.0, p18)
  & absRegState . boundValue DF .~ BoolConst False
  & startAbsStack .~ Map.singleton 0 (StackEntry (BVMemRepr n8 LittleEndian) ReturnAddr)

preserveFreeBSDSyscallReg :: X86Reg tp -> Bool
preserveFreeBSDSyscallReg r
  | Just Refl <- testEquality r CF  = False
  | Just Refl <- testEquality r RAX = False
  | otherwise = True

-- | Linux preserves the same registers the x86_64 ABI does
linuxSystemCallPreservedRegisters :: Set.Set (Some X86Reg)
linuxSystemCallPreservedRegisters = x86CalleeSavedRegs


-- | Transfer some type into an abstract value given a processor state.
transferAbsValue :: AbsProcessorState X86Reg ids
                 -> X86PrimFn (Value X86_64 ids) tp
                 -> AbsValue 64 tp
transferAbsValue r f =
  case f of
    EvenParity _ -> TopV
    ReadLoc _  -> TopV
    ReadFSBase -> TopV
    ReadGSBase -> TopV
    CPUID _    -> TopV
    CMPXCHG8B{} -> TopV
    RDTSC      -> TopV
    XGetBV _   -> TopV
    PShufb{}   -> TopV
      -- We know only that it will return up to (and including(?)) cnt
    MemCmp _sz cnt _src _dest _rev
      | Just upper <- hasMaximum knownRepr (transferValue r cnt) ->
          stridedInterval $ SI.mkStridedInterval knownNat False 0 upper 1
      | otherwise -> TopV
    RepnzScas _sz _val _buf cnt
      | Just upper <- hasMaximum knownRepr (transferValue r cnt) ->
          stridedInterval $ SI.mkStridedInterval knownNat False 0 upper 1
      | otherwise -> TopV
    MMXExtend{}   -> TopV
    X86IDiv{} -> TopV
    X86IRem{} -> TopV
    X86Div{}  -> TopV
    X86Rem{}  -> TopV
    SSE_VectorOp{}  -> TopV
    SSE_CMPSX{}  -> TopV
    SSE_UCOMIS{}  -> TopV
    SSE_CVTSD2SS{}  -> TopV
    SSE_CVTSS2SD{}  -> TopV
    SSE_CVTSI2SX{}  -> TopV
    SSE_CVTTSX2SI{}  -> TopV
    X87_Extend{}  -> TopV
    X87_FST{}  -> TopV
    X87_FAdd{}  -> TopV
    X87_FSub{}  -> TopV
    X87_FMul{}  -> TopV

    -- XXX: Is 'TopV' the right thing for the AVX instruction below?
    VOp1 {} -> TopV
    VOp2 {} -> TopV
    Pointwise2 {} -> TopV
    PointwiseShiftL {} -> TopV
    VExtractF128 {} -> TopV
    VInsert {} -> TopV

-- | Disassemble block, returning either an error, or a list of blocks
-- and ending PC.
tryDisassembleBlockFromAbsState :: forall s ids
                                .  NonceGenerator (ST s) ids
                                -> MemSegmentOff 64
                                -- ^ Address to disassemble at
                                -> Int
                                -- ^ Maximum size of this block
                                -> AbsBlockState X86Reg
                                -- ^ Abstract state of processor for defining state.
                                -> ExceptT String (ST s) (Block X86_64 ids, Int, Maybe String)
tryDisassembleBlockFromAbsState nonceGen addr maxSize ab = do
  t <-
    case asConcreteSingleton (ab^.absRegState^.boundValue X87_TopReg) of
      Nothing -> throwError "Could not determine height of X87 stack."
      Just t -> pure t
  d <-
    case asConcreteSingleton (ab^.absRegState^.boundValue DF) of
      Nothing -> do
        throwError $ "Could not determine df flag " ++ show (ab^.absRegState^.boundValue DF)
      Just d -> pure d
  let loc = ExploreLoc { loc_ip = addr
                       , loc_x87_top = fromInteger t
                       , loc_df_flag = d /= 0
                       }
  let off = msegOffset  addr
  let pblock = emptyPreBlock (initX86State loc) 0
  (b, nextIPOff, maybeError) <- lift $
    case contentsAfterSegmentOff addr of
      Left msg -> do
        initError loc (FlexdisMemoryError msg)
      Right contents -> do
        disassembleBlockImpl nonceGen pblock addr (off + fromIntegral maxSize) contents
  let sz :: Int
      sz = fromIntegral $ nextIPOff - off
  pure $! (b, sz, show <$> maybeError)

-- | Disassemble block, returning either an error, or a list of blocks
-- and ending PC.
disassembleBlockFromAbsState :: forall s ids
                             .  NonceGenerator (ST s) ids
                             -> MemSegmentOff 64
                             -- ^ Address to disassemble at
                             -> Int
                             -- ^ Maximum size of this block
                             -> AbsBlockState X86Reg
                             -- ^ Abstract state of processor for defining state.
                             -> ST s ([Block X86_64 ids], Int, Maybe String)
disassembleBlockFromAbsState nonceGen addr maxSize ab = do
  mr <- runExceptT $ tryDisassembleBlockFromAbsState nonceGen addr maxSize ab
  case mr of
    Left msg -> pure ([], 0, Just msg)
    Right (b,sz, merr) ->  pure ([b],sz,merr)

-- | Attempt to identify the write to a stack return address, returning
-- instructions prior to that write and return  values.
--
-- This can also return Nothing if the call is not supported.
identifyX86Call :: Memory 64
                -> [Stmt X86_64 ids]
                -> RegState X86Reg (Value X86_64 ids)
                -> Maybe (Seq (Stmt X86_64 ids), MemSegmentOff 64)
identifyX86Call mem stmts0 s = go (Seq.fromList stmts0) Seq.empty
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
              , Just val_a <- valueAsMemAddr val
                -- Check if segment of address is marked as executable.
              , Just ret_addr <- asSegmentOff mem val_a
              , segmentFlags (msegSegment ret_addr) `Perm.hasPerm` Perm.execute ->
                Just (prev Seq.>< after, ret_addr)
                -- Stop if we hit any architecture specific instructions prior to
                -- identifying return address since they may have side effects.
              | ExecArchStmt _ <- stmt -> Nothing
                -- Otherwise skip over this instruction.
              | otherwise -> go prev (stmt Seq.<| after)

-- | Called to determine if the instruction sequence contains a return
-- from the current function.
--
-- An instruction executing a return from a function will place the
-- ReturnAddr value (placed on the top of the stack by
-- 'initialX86AbsState' above) into the instruction pointer.
identifyX86Return :: [Stmt X86_64 ids]
                  -> RegState X86Reg (Value X86_64 ids)
                  -> AbsProcessorState X86Reg ids
                  -> Maybe (Seq (Stmt X86_64 ids))
identifyX86Return stmts s finalRegSt8 =
  case transferValue finalRegSt8 (s^.boundValue ip_reg) of
    ReturnAddr -> Just $ Seq.fromList stmts
    _ -> Nothing

-- | Return state post call
x86PostCallAbsState :: AbsBlockState X86Reg
                    -> MemSegmentOff 64
                    -> AbsBlockState X86Reg
x86PostCallAbsState =
  let params = CallParams { postCallStackDelta = 8
                          , preserveReg = \r -> Set.member (Some r) x86CalleeSavedRegs
                          }
   in absEvalCall params

freeBSD_syscallPersonality :: SyscallPersonality
freeBSD_syscallPersonality =
  SyscallPersonality { spTypeInfo = FreeBSD.syscallInfo
                     , spResultRegisters = [ Some RAX ]
                     }

x86DemandContext :: DemandContext X86_64
x86DemandContext =
  DemandContext { demandConstraints = \a -> a
                , archFnHasSideEffects = x86PrimFnHasSideEffects
                }

postX86TermStmtAbsState :: (forall tp . X86Reg tp -> Bool)
                        -> Memory 64
                        -> AbsBlockState X86Reg
                        -> RegState X86Reg (Value X86_64 ids)
                        -> X86TermStmt ids
                        -> Maybe (MemSegmentOff 64, AbsBlockState X86Reg)
postX86TermStmtAbsState preservePred mem s regs tstmt =
  case tstmt of
    X86Syscall ->
      case regs^.curIP of
        RelocatableValue _ addr | Just nextIP <- asSegmentOff mem addr -> do
          let params = CallParams { postCallStackDelta = 0
                                  , preserveReg = preservePred
                                  }
          Just (nextIP, absEvalCall params s nextIP)
        _ -> error $ "Sycall could not interpret next IP"
    Hlt ->
      Nothing
    UD2 ->
      Nothing

-- | Common architecture information for X86_64
x86_64_info :: (forall tp . X86Reg tp -> Bool)
               -- ^ Function that returns true if we should preserve a register across a system call.
            -> ArchitectureInfo X86_64
x86_64_info preservePred =
  ArchitectureInfo { withArchConstraints = \x -> x
                   , archAddrWidth      = Addr64
                   , archEndianness     = LittleEndian
                   , disassembleFn      = disassembleBlockFromAbsState
                   , mkInitialAbsState = \_ addr -> initialX86AbsState addr
                   , absEvalArchFn     = transferAbsValue
                   , absEvalArchStmt   = \s _ -> s
                   , postCallAbsState = x86PostCallAbsState
                   , identifyCall      = identifyX86Call
                   , identifyReturn    = identifyX86Return
                   , rewriteArchFn     = rewriteX86PrimFn
                   , rewriteArchStmt   = rewriteX86Stmt
                   , rewriteArchTermStmt = rewriteX86TermStmt
                   , archDemandContext = x86DemandContext
                   , postArchTermStmtAbsState = postX86TermStmtAbsState preservePred
                   }

-- | Architecture information for X86_64 on FreeBSD.
x86_64_freeBSD_info :: ArchitectureInfo X86_64
x86_64_freeBSD_info = x86_64_info preserveFreeBSDSyscallReg

linux_syscallPersonality :: SyscallPersonality
linux_syscallPersonality =
  SyscallPersonality { spTypeInfo = Linux.syscallInfo
                     , spResultRegisters = [Some RAX]
                     }

-- | Architecture information for X86_64.
x86_64_linux_info :: ArchitectureInfo X86_64
x86_64_linux_info = x86_64_info preserveFn
  where preserveFn r = Set.member (Some r) linuxSystemCallPreservedRegisters
