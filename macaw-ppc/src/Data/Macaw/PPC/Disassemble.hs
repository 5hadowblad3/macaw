{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
module Data.Macaw.PPC.Disassemble ( disassembleFn ) where

import           Control.Lens ( (^.) )
import           Control.Monad ( unless )
import qualified Control.Monad.Except as ET
import           Control.Monad.ST ( ST )
import           Control.Monad.Trans ( lift )
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Foldable as F
import           Data.Word ( Word64 )

import qualified Dismantle.PPC as D

import           Data.Macaw.AbsDomain.AbsState as MA
import           Data.Macaw.CFG
import           Data.Macaw.CFG.Block
import qualified Data.Macaw.CFG.Core as MC
import qualified Data.Macaw.Memory as MM
import qualified Data.Macaw.Memory.Permissions as MMP
import qualified Data.Parameterized.Nonce as NC

import           Data.Macaw.PPC.Generator

type LocatedFailure ppc s = ([Block ppc s], MM.MemWord (RegAddrWidth (ArchReg ppc)), TranslationError (RegAddrWidth (ArchReg ppc)))
newtype DisM ppc s a = DisM { unDisM :: ET.ExceptT (LocatedFailure ppc s) (ST s) a }
  deriving (Functor,
            Applicative,
            Monad,
            ET.MonadError (LocatedFailure ppc s))

data TranslationError w = TranslationError { transErrorAddr :: MM.MemSegmentOff w
                                           , transErrorReason :: TranslationErrorReason w
                                           }

data TranslationErrorReason w = InvalidNextIP Word64 Word64
                              | DecodeError (MM.MemoryError w)
                              deriving (Show)

deriving instance (MM.MemWidth w) => Show (TranslationError w)

liftST :: ST s a -> DisM ppc s a
liftST = DisM . lift

-- | Read one instruction from the 'MM.Memory' at the given segmented offset.
--
-- Returns the instruction and number of bytes consumed /or/ an error.
readInstruction :: MM.Memory w
                -> MM.MemSegmentOff w
                -> Either (MM.MemoryError w) (D.Instruction, MM.MemWord w)
readInstruction mem addr = MM.addrWidthClass (MM.memAddrWidth mem) $ do
  let seg = MM.msegSegment addr
  case MM.segmentFlags seg `MMP.hasPerm` MMP.execute of
    False -> ET.throwError (MM.PermissionsError (MM.relativeSegmentAddr addr))
    True -> do
      contents <- MM.addrContentsAfter mem (MM.relativeSegmentAddr addr)
      case contents of
        [] -> ET.throwError (MM.AccessViolation (MM.relativeSegmentAddr addr))
        MM.SymbolicRef {} : _ ->
          ET.throwError (MM.UnexpectedRelocation (MM.relativeSegmentAddr addr))
        MM.ByteRegion bs : _rest
          | BS.null bs -> ET.throwError (MM.AccessViolation (MM.relativeSegmentAddr addr))
          | otherwise -> do
            let (bytesRead, minsn) = D.disassembleInstruction (LBS.fromStrict bs)
            case minsn of
              Just insn -> return (insn, fromIntegral bytesRead)
              Nothing -> ET.throwError (MM.InvalidInstruction (MM.relativeSegmentAddr addr) contents)

failAt :: GenState ppc s ids
       -> MM.MemWord (ArchAddrWidth ppc)
       -> MM.MemSegmentOff (ArchAddrWidth ppc)
       -> TranslationErrorReason (ArchAddrWidth ppc)
       -> DisM ppc s a
failAt gs offset curIPAddr reason = do
  let exn = TranslationError { transErrorAddr = curIPAddr
                             , transErrorReason = reason
                             }
  undefined  ([], offset, exn)

disassembleBlock :: MM.Memory (ArchAddrWidth ppc)
                 -> GenState ppc s ids
                 -> MM.MemSegmentOff (ArchAddrWidth ppc)
                 -> MM.MemWord (ArchAddrWidth ppc)
                 -> DisM ppc s (MM.MemWord (ArchAddrWidth ppc), GenState ppc s ids)
disassembleBlock mem gs curIPAddr maxOffset = do
  let seg = MM.msegSegment curIPAddr
  let off = MM.msegOffset curIPAddr
  case readInstruction mem curIPAddr of
    Left err -> failAt gs off curIPAddr (DecodeError err)
    Right (i, bytesRead) -> do
      -- let nextIP = MM.relativeAddr seg (off + bytesRead)
      -- let nextIPVal = MC.RelocatableValue undefined nextIP
      undefined

tryDisassembleBlock :: (MM.MemWidth (ArchAddrWidth ppc))
                    => MM.Memory (ArchAddrWidth ppc)
                    -> NC.NonceGenerator (ST s) s
                    -> ArchSegmentOff ppc
                    -> ArchAddrWord ppc
                    -> DisM ppc s ([Block ppc s], MM.MemWord (ArchAddrWidth ppc))
tryDisassembleBlock mem nonceGen startAddr maxSize = do
  let gs0 = initGenState nonceGen startAddr
  let startOffset = MM.msegOffset startAddr
  (nextIPOffset, gs1) <- disassembleBlock mem gs0 startAddr (startOffset + maxSize)
  unless (nextIPOffset > startOffset) $ do
    let reason = InvalidNextIP (fromIntegral nextIPOffset) (fromIntegral startOffset)
    failAt gs1 nextIPOffset startAddr reason
  let blocks = F.toList (blockSeq gs1 ^. frontierBlocks)
  return (blocks, nextIPOffset - startOffset)

-- | Disassemble a block from the given start address (which points into the
-- 'MM.Memory').
--
-- Return a list of disassembled blocks as well as the total number of bytes
-- occupied by those blocks.
disassembleFn :: (MM.MemWidth (RegAddrWidth (ArchReg ppc)))
              => proxy ppc
              -> MM.Memory (ArchAddrWidth ppc)
              -> NC.NonceGenerator (ST ids) ids
              -> ArchSegmentOff ppc
              -- ^ The address to disassemble from
              -> ArchAddrWord ppc
              -- ^ Maximum size of the block (a safeguard)
              -> MA.AbsBlockState (ArchReg ppc)
              -- ^ Abstract state of the processor at the start of the block
              -> ST ids ([Block ppc ids], MM.MemWord (ArchAddrWidth ppc), Maybe String)
disassembleFn _ mem nonceGen startAddr maxSize _  = do
  mr <- ET.runExceptT (unDisM (tryDisassembleBlock mem nonceGen startAddr maxSize))
  case mr of
    Left (blocks, off, exn) -> return (blocks, off, Just (show exn))
    Right (blocks, bytes) -> return (blocks, bytes, Nothing)
