{-
Copyright        : (c) Galois, Inc 2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>

This provides a facility for disassembling x86 instructions from a
Macaw memory object.
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
module Data.Macaw.X86.Flexdis
  ( MemoryByteReader
  , X86TranslateError(..)
  , runMemoryByteReader
  , readInstruction
  , readInstruction'
  ) where

import           Control.Monad.Except
import           Control.Monad.State.Strict
import Data.Bits
import qualified Data.ByteString as BS
import Data.Int
import           Data.Text (Text)
import           Data.Text as Text
import Data.Word

import           Data.Macaw.Memory
import qualified Data.Macaw.Memory.Permissions as Perm

import qualified Flexdis86 as Flexdis
import           Flexdis86.ByteReader

------------------------------------------------------------------------
-- MemStream

-- | A stream of memory
data MemStream w = MS { msInitial :: ![SegmentRange w]
                      , msSegment :: !(MemSegment w)
                        -- ^ The current segment
                      , msStart :: !(MemWord w)
                        -- ^ The initial offset for the stream.
                      , msOffset :: !(MemWord w)
                        -- ^ The current address
                      , msNext :: ![SegmentRange w]
                        -- ^ The next bytes to read.
                      }

msStartAddr :: MemWidth w => MemStream w -> MemAddr w
msStartAddr ms = relativeAddr (msSegment ms) (msStart ms)

msAddr :: MemWidth w => MemStream w -> MemAddr w
msAddr ms = relativeAddr (msSegment ms) (msOffset ms)

------------------------------------------------------------------------
-- MemoryByteReader

-- | Describes the reason the translation error occured.
data X86TranslateError w
   = FlexdisMemoryError !(MemoryError w)
     -- ^ A memory error occured in decoding with Flexdis
   | InvalidInstruction !(MemAddr w) ![SegmentRange w]
     -- ^ The memory reader could not parse the value starting at the given address
     -- the last byte read was at the offset.
   | UserMemoryError !(MemAddr w) !String
     -- ^ the memory reader threw an unspecified error at the given location.
   | UnsupportedInstruction !(MemSegmentOff w) !Flexdis.InstructionInstance
     -- ^ The instruction is not supported by the translator
   | ExecInstructionError !(MemSegmentOff w) !Flexdis.InstructionInstance Text
     -- ^ An error occured when trying to translate the instruction

instance MemWidth w => Show (X86TranslateError w) where
  show err =
    case err of
      FlexdisMemoryError me ->
        show me
      InvalidInstruction start rng ->
        "Invalid instruction at " ++ show start ++ ": " ++ show rng
      UserMemoryError addr msg ->
        "Memory error " ++ show addr ++ ": " ++ msg
      UnsupportedInstruction addr i ->
        "Unsupported instruction at " ++ show addr ++ ": " ++ show i
      ExecInstructionError addr i msg ->
        "Error in interpretting instruction at " ++ show addr ++ ": " ++ show i ++ "\n  "
        ++ Text.unpack msg

newtype MemoryByteReader w a = MBR { unMBR :: ExceptT (X86TranslateError w) (State (MemStream w)) a }
  deriving (Functor, Applicative, MonadError (X86TranslateError w))

instance MemWidth w => Monad (MemoryByteReader w) where
  return = MBR . return
  MBR m >>= f = MBR $ m >>= unMBR . f
  fail msg = do
    addr <- MBR $ gets msAddr
    throwError $ UserMemoryError addr msg

-- | Run a memory byte reader starting from the given offset and offset for next.
runMemoryByteReader' :: MemSegmentOff w -- ^ Starting segment
                     -> [SegmentRange w] -- ^ Data to read next.
                     -> MemoryByteReader w a -- ^ Byte reader to read values from.
                     -> Either (X86TranslateError w) (a, MemWord w)
runMemoryByteReader' addr contents (MBR m) = do
  let ms0 = MS { msInitial = contents
               , msSegment = msegSegment addr
               , msStart   = msegOffset addr
               , msOffset  = msegOffset addr
               , msNext    = contents
               }
  case runState (runExceptT m) ms0 of
    (Left e, _) -> Left e
    (Right v, ms) -> Right (v, msOffset ms)

-- | Create a memory stream pointing to given address, and return pair whose
-- first element is the value read or an error, and whose second element is
-- the address of the next value to read.
runMemoryByteReader :: Memory w
                    -> Perm.Flags
                       -- ^ Permissions that memory accesses are expected to
                       -- satisfy.
                       -- Added so we can check for read and/or execute permission.
                    -> MemSegmentOff w -- ^ Starting segment
                    -> MemoryByteReader w a -- ^ Byte reader to read values from.
                    -> Either (X86TranslateError w) (a, MemWord w)
runMemoryByteReader mem reqPerm addr m =
  addrWidthClass (memAddrWidth mem) $ do
  let seg = msegSegment addr
  if not (segmentFlags seg `Perm.hasPerm` reqPerm) then
    Left $ FlexdisMemoryError $ PermissionsError (relativeSegmentAddr addr)
   else
    case addrContentsAfter mem (relativeSegmentAddr addr) of
      Right contents -> runMemoryByteReader' addr contents m
      Left e -> Left (FlexdisMemoryError e)

throwMemoryError :: MemoryError w -> MemoryByteReader w a
throwMemoryError e = MBR $ throwError (FlexdisMemoryError e)

sbyte :: (Bits w, Num w) => Word8 -> Int -> w
sbyte w o = fromIntegral i8 `shiftL` (8*o)
  where i8 :: Int8
        i8 = fromIntegral w

ubyte :: (Bits w, Num w) => Word8 -> Int -> w
ubyte w o = fromIntegral w `shiftL` (8*o)

jsizeCount :: Flexdis.JumpSize -> Int
jsizeCount Flexdis.JSize8  = 1
jsizeCount Flexdis.JSize16 = 2
jsizeCount Flexdis.JSize32 = 4

getUnsigned32 :: MemWidth w => BS.ByteString -> MemoryByteReader w Word32
getUnsigned32 s =
  case BS.unpack s of
    w0:w1:w2:w3:_ -> do
      pure $! ubyte w3 3 .|. ubyte w2 2 .|. ubyte w1 1 .|. ubyte w0 0
    _ -> do
      ms <- MBR get
      throwMemoryError $ AccessViolation (msAddr ms)

getJumpBytes :: MemWidth w => BS.ByteString -> Flexdis.JumpSize -> MemoryByteReader w (Int64, Int)
getJumpBytes s sz =
  case (sz, BS.unpack s) of
    (Flexdis.JSize8, w0:_) -> do
      pure (sbyte w0 0, 1)
    (Flexdis.JSize16, w0:w1:_) -> do
      pure (sbyte w1 1 .|. ubyte w0 0, 2)
    (Flexdis.JSize32, _) -> do
      v <- getUnsigned32 s
      pure (fromIntegral (fromIntegral v :: Int32), 4)
    _ -> do
      ms <- MBR get
      throwMemoryError $ AccessViolation (msAddr ms)

updateMSByteString :: MemWidth w
                   => MemStream w
                   -> BS.ByteString
                   -> [SegmentRange w]
                   -> MemWord w
                   -> MemoryByteReader w ()
updateMSByteString ms bs rest c = do
  let bs' = BS.drop (fromIntegral (memWordInteger c)) bs
  let ms' = ms { msOffset = msOffset ms + c
               , msNext   =
                 if BS.null bs' then
                   rest
                  else
                   ByteRegion bs' : rest
               }
  seq ms' $ MBR $ put ms'


instance MemWidth w => ByteReader (MemoryByteReader w) where
  readByte = do
    ms <- MBR get
    -- If remaining bytes are empty
    case msNext ms of
      [] ->
        throwMemoryError $ AccessViolation (msAddr ms)
      -- Throw error if we try to read a relocation as a symbolic reference
      BSSRegion _:_ -> do
        throwMemoryError $ UnexpectedBSS (msAddr ms)
      RelocationRegion r:_ -> do
        throwMemoryError $ UnexpectedRelocation (msAddr ms) r "byte0"
      ByteRegion bs:rest -> do
        if BS.null bs then do
          throwMemoryError $ AccessViolation (msAddr ms)
         else do
          let v = BS.head bs
          updateMSByteString ms bs rest 1
          pure $! v

  readDImm = do
    ms <- MBR get
    -- If remaining bytes are empty
    case msNext ms of
      [] ->
        throwMemoryError $ AccessViolation (msAddr ms)
      -- Throw error if we try to read a relocation as a symbolic reference
      BSSRegion _:_ -> do
        throwMemoryError $ UnexpectedBSS (msAddr ms)
      RelocationRegion r:rest -> do
        case r of
          AbsoluteRelocation sym off end szCnt -> do
            unless (szCnt == 4 && end == LittleEndian) $ do
              throwMemoryError $ UnexpectedRelocation (msAddr ms) r "dimm0"
            let ms' = ms { msOffset = msOffset ms + 4
                         , msNext   = rest
                         }
            seq ms' $ MBR $ put ms'
            pure $ Flexdis.Imm32SymbolOffset sym (fromIntegral off)
            -- RelativeOffset addr ioff (fromIntegral off)
          RelativeRelocation _addr _off _end _szCnt -> do
            throwMemoryError $ UnexpectedRelocation (msAddr ms) r "dimm1"

      ByteRegion bs:rest -> do
        v <- getUnsigned32 bs
        updateMSByteString ms bs rest 4
        pure $! Flexdis.Imm32Concrete v

  readJump sz = do
    ms <- MBR get
    -- If remaining bytes are empty
    case msNext ms of
      [] ->
        throwMemoryError $ AccessViolation (msAddr ms)
      -- Throw error if we try to read a relocation as a symbolic reference
      BSSRegion _:_ -> do
        throwMemoryError $ UnexpectedBSS (msAddr ms)
      RelocationRegion r:rest -> do
        case r of
          AbsoluteRelocation{} -> do
            throwMemoryError $ UnexpectedRelocation (msAddr ms) r "jump0"
          RelativeRelocation addr off end szCnt -> do
            when (szCnt /= jsizeCount sz) $ do
              throwMemoryError $ UnexpectedRelocation (msAddr ms) r "jump1"
            when (end /= LittleEndian) $ do
              throwMemoryError $ UnexpectedRelocation (msAddr ms) r "jump2"
            let ms' = ms { msOffset = msOffset ms + fromIntegral (jsizeCount sz)
                         , msNext   = rest
                         }
            seq ms' $ MBR $ put ms'
            let ioff = fromIntegral $ msOffset ms - msStart ms
            pure $ Flexdis.RelativeOffset addr ioff (fromIntegral off)
      ByteRegion bs:rest -> do
        (v,c) <- getJumpBytes bs sz
        updateMSByteString ms bs rest (fromIntegral c)
        pure (Flexdis.FixedOffset v)


  invalidInstruction = do
    ms <- MBR $ get
    throwError $ InvalidInstruction (msStartAddr ms)
      (takeSegmentPrefix (msInitial ms) (msOffset ms - msStart ms))

------------------------------------------------------------------------
-- readInstruction


-- | Read instruction at a given memory address.
readInstruction' :: MemSegmentOff 64
                    -- ^ Address to read from.
                 -> [SegmentRange 64] -- ^ Data to read next.
                 -> Either (X86TranslateError 64)
                           (Flexdis.InstructionInstance, MemWord 64)
readInstruction' addr contents = do
  let seg = msegSegment addr
  if not (segmentFlags seg `Perm.hasPerm` Perm.execute) then
    Left $ FlexdisMemoryError $ PermissionsError (relativeSegmentAddr addr)
   else do
    runMemoryByteReader' addr contents Flexdis.disassembleInstruction

-- | Read instruction at a given memory address.
readInstruction :: Memory 64
                -> MemSegmentOff 64
                   -- ^ Address to read from.
                -> Either (X86TranslateError 64)
                          (Flexdis.InstructionInstance, MemWord 64)
readInstruction mem addr = do
  case addrContentsAfter mem (relativeSegmentAddr addr) of
    Left e -> Left (FlexdisMemoryError e)
    Right l -> readInstruction' addr l
