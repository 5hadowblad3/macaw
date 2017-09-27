{-|
Copyright        : (c) Galois, Inc 2015-2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>

This module provides definitions for x86 instructions.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
module Data.Macaw.X86.Semantics
  ( execInstruction
  ) where

import           Prelude hiding (isNaN)
import           Data.Foldable
import           Data.Int
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Parameterized.NatRepr
import           Data.Parameterized.Some
import           Data.Proxy
import qualified Flexdis86 as F

import           Data.Macaw.CFG (MemRepr(..), memReprBytes)
import           Data.Macaw.Memory (Endianness (LittleEndian))
import           Data.Macaw.Types

import           Data.Macaw.X86.Getters
import           Data.Macaw.X86.InstructionDef
import           Data.Macaw.X86.Monad
import           Data.Macaw.X86.X86Reg (X86Reg)
import qualified Data.Macaw.X86.X86Reg as R

-- * Preliminaries

-- The representation for a address
addrRepr :: MemRepr (BVType 64)
addrRepr = BVMemRepr n8 LittleEndian

type Binop = forall m n.
  IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()

uadd4_overflows :: ( 4 <= n, IsValue v)
                => v (BVType n) -> v (BVType n) -> v BoolType
uadd4_overflows x y = uadd_overflows (least_nibble x) (least_nibble y)

usub4_overflows :: (4 <= n, IsValue v)
                => v (BVType n) -> v (BVType n) -> v BoolType
usub4_overflows x y = usub_overflows (least_nibble x) (least_nibble y)

uadc4_overflows :: ( 4 <= n
                   , IsValue v
                   )
                => v (BVType n) -> v (BVType n) -> v BoolType -> v BoolType
uadc4_overflows x y c = uadc_overflows (least_nibble x) (least_nibble y) c

fmap_loc :: Semantics m => MLocation m (BVType n) -> (Value m (BVType n) -> Value m (BVType n)) -> m ()
fmap_loc l f = do
  lv <- get l
  l .= f lv

-- | Update flags with given result value.
set_result_flags :: IsLocationBV m n => Value m (BVType n) -> m ()
set_result_flags res = do
  sf_loc .= msb res
  zf_loc .= is_zero res
  pf_loc .= even_parity (least_byte res)

-- | Assign value to location and update corresponding flags.
set_result_value :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
set_result_value dst res = do
  set_result_flags res
  dst .= res

-- | Set bitwise flags.
set_bitwise_flags :: IsLocationBV m n => Value m (BVType n) -> m ()
set_bitwise_flags res = do
  of_loc .= false
  cf_loc .= false
  set_undefined af_loc
  set_result_flags res

push :: Semantics m => MemRepr tp -> Value m tp -> m ()
push repr v = do
  old_sp <- get rsp
  let delta   = bvLit n64 $ memReprBytes repr -- delta in bytes
      new_sp  = old_sp `bvSub` delta
  MemoryAddr new_sp repr .= v
  rsp     .= new_sp

pop :: Semantics m => MemRepr tp -> m (Value m tp)
pop repr = do
  -- Get current stack pointer value.
  old_sp <- get rsp
  -- Get value at stack pointer.
  v   <- get (MemoryAddr old_sp repr)
  -- Increment stack pointer
  rsp .= bvAdd old_sp (bvLit n64 (memReprBytes repr))
  -- Return value
  return v

dwordLoc  :: Semantics m => F.AddrRef -> m (MLocation m (BVType 32))
dwordLoc addr = (`MemoryAddr` dwordMemRepr) <$> getBVAddress addr

readDWord :: Semantics m => F.AddrRef -> m (Value m (BVType 32))
readDWord addr = get =<< dwordLoc addr

qwordLoc  :: Semantics m => F.AddrRef -> m (MLocation m (BVType 64))
qwordLoc addr = (`MemoryAddr` qwordMemRepr) <$> getBVAddress addr

readQWord :: Semantics m => F.AddrRef -> m (Value m (BVType 64))
readQWord addr = get =<< qwordLoc addr

-- | Read a 32 or 64-bit register
getReg32_Reg64 :: Monad m => F.Value -> m (Either (MLocation m (BVType 32)) (MLocation m (BVType 64)))
getReg32_Reg64 v =
  case v of
    F.DWordReg r -> pure $ Left  $ reg_low32    $ R.X86_GP $ F.reg32_reg r
    F.QWordReg r -> pure $ Right $ fullRegister $ R.X86_GP r
    _ -> fail "Unexpected operand"

-- | Read a 32 or 64-bit register or meory value
getRM32_RM64 :: Semantics m => F.Value -> m (Either (MLocation m (BVType 32)) (MLocation m (BVType 64)))
getRM32_RM64 v =
  case v of
    F.DWordReg r -> pure $ Left  $ reg_low32    $ R.X86_GP $ F.reg32_reg r
    F.QWordReg r -> pure $ Right $ fullRegister $ R.X86_GP r
    F.Mem32 addr -> Left  <$> dwordLoc addr
    F.Mem64 addr -> Right <$> qwordLoc addr
    _ -> fail "Unexpected operand"

-- | Location that get the high 64 bits of a XMM register,
-- and preserves the low 64 bits on writes.
xmm_loc :: F.XMMReg -> Location addr (BVType 128)
xmm_loc r = fullRegister (R.X86_XMMReg r)

-- | Location that get the low 64 bits of a XMM register,
-- and preserves the high 64 bits on writes.
xmm_low32 :: F.XMMReg -> Location addr (BVType 32)
xmm_low32 r = subRegister n0 n32 (R.X86_XMMReg r)

-- | Location that get the low 64 bits of a XMM register,
-- and preserves the high 64 bits on writes.
xmm_low64 :: F.XMMReg -> Location addr (BVType 64)
xmm_low64 r = subRegister n0 n64 (R.X86_XMMReg r)

-- | Location that get the high 64 bits of a XMM register,
-- and preserves the low 64 bits on writes.
xmm_high64 :: F.XMMReg -> Location addr (BVType 64)
xmm_high64 r = subRegister n64 n64 (R.X86_XMMReg r)

-- | This gets the register of a xmm field.
getXMM :: Monad m => F.Value -> m F.XMMReg
getXMM (F.XMMReg r) = pure r
getXMM _ = fail "Unexpected argument"

-- | This gets the value of a xmm/m32 field.
--
-- If it is an XMM value, it gets the low 32bit register.
-- If it is a memory address is gets the 32bits there.
-- Otherwise it fails.
getXMM_mr_low32 :: Semantics m => F.Value -> m (MLocation m (FloatType SingleFloat))
getXMM_mr_low32 (F.XMMReg r) = pure (xmm_low32 r)
getXMM_mr_low32 (F.Mem128 src_addr) = dwordLoc src_addr
getXMM_mr_low32 _ = fail "Unexpected argument"

-- | This gets the value of a xmm/m64 field.
--
-- If it is an XMM value, it gets the low 64bit register.
-- If it is a memory address is gets the 64bits there.
-- Otherwise it fails.
getXMM_mr_low64 :: Semantics m => F.Value -> m (MLocation m (FloatType DoubleFloat))
getXMM_mr_low64 (F.XMMReg r) = pure (xmm_low64 r)
getXMM_mr_low64 (F.Mem128 src_addr) = qwordLoc src_addr
getXMM_mr_low64 _ = fail "Unexpected argument"

-- ** Condition codes

-- * General Purpose Instructions
-- ** Data Transfer Instructions

-- FIXME: has the side effect of reading r, but this should be safe because r can only be a register.

def_cmov_list :: [InstructionDef]
def_cmov_list =
  defConditionals "cmov" $ \mnem cc ->
    defBinaryLV mnem $ \r y -> do
      c <- cc
      r_v <- get r
      r .= mux c y r_v

-- | Run bswap instruction.
exec_bswap :: IsLocationBV m n => MLocation m (BVType n) -> m ()
exec_bswap l = do
  v0 <- get l
  l .= (bvUnvectorize (typeWidth l) $ reverse $ bvVectorize n8 v0)

def_xadd :: InstructionDef
def_xadd =
  defBinaryLL "xadd" $ \_ d s -> do
    d0 <- get d
    s0 <- get s
    s .= d0
    exec_add d s0 -- sets flags

-- | Sign extend al -> ax, ax -> eax, eax -> rax, resp.
def_cbw :: InstructionDef
def_cbw = defNullary "cbw" $ do
  v <- get al
  ax .= sext n16 v

def_cwde :: InstructionDef
def_cwde = defNullary "cwde" $ do
  v <- get ax
  eax .= sext n32 v

def_cdqe :: InstructionDef
def_cdqe = defNullary "cdqe" $ do
  v <- get eax
  rax .= sext n64 v

def_pop :: InstructionDef
def_pop =
  defUnary "pop" $ \_ fval -> do
    Some (HasRepSize rep l) <- getAddrRegOrSegment fval
    val <- pop (repValSizeMemRepr rep)
    l .= val

def_push :: InstructionDef
def_push =
  defUnary "push" $ \_ val -> do
    Some (HasRepSize rep v) <- getAddrRegSegmentOrImm val
    push (repValSizeMemRepr rep) v

-- | Sign extend ax -> dx:ax, eax -> edx:eax, rax -> rdx:rax, resp.
def_cwd :: InstructionDef
def_cwd = defNullary "cwd" $ do
  v <- get ax
  let (upper, lower) = bvSplit (sext n32 v)
  dx .= upper
  ax .= lower

def_cdq :: InstructionDef
def_cdq = defNullary "cdq" $ do
  v <- get eax
  let (upper, lower) = bvSplit (sext n64 v)
  edx .= upper
  eax .= lower

def_cqo :: InstructionDef
def_cqo = defNullary "cqo" $ do
  v <- get rax
  let (upper, lower) = bvSplit (sext knownNat v)
  rdx .= upper
  rax .= lower

-- FIXME: special segment stuff?
-- FIXME: CR and debug regs?
exec_mov :: Semantics m =>  MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_mov l v = l .= v

regLocation :: NatRepr n -> X86Reg (BVType 64) -> Location addr (BVType n)
regLocation sz
  | Just Refl <- testEquality sz n8  = reg_low8
  | Just Refl <- testEquality sz n16 = reg_low16
  | Just Refl <- testEquality sz n32 = reg_low32
  | Just Refl <- testEquality sz n64 = fullRegister
  | otherwise = fail "regLocation: Unknown bit width"

def_cmpxchg :: InstructionDef
def_cmpxchg  = defBinaryLV "cmpxchg" $ \d s -> do
  let acc = regLocation (bv_width s) R.RAX
  temp <- get d
  a  <- get acc
  exec_cmp acc temp -- set flags
  ifte_ (a .=. temp)
        (do zf_loc .= true
            d .= s
        )
        (do zf_loc .= false
            acc .= temp
            d   .= temp
        )

exec_cmpxchg8b :: Semantics m => MLocation m (BVType 64) -> m ()
exec_cmpxchg8b loc = do
  temp64 <- get loc
  edx_eax <- bvCat <$> get edx <*> get eax
  ifte_ (edx_eax .=. temp64)
    (do zf_loc .= true
        ecx_ebx <- bvCat <$> get ecx <*> get ebx
        loc .= ecx_ebx
    )
    (do zf_loc .= false
        let (upper,lower) = bvSplit temp64
        edx .= upper
        eax .= lower
        loc .= edx_eax -- FIXME: this store is redundant, but it is in the ISA, so we do it.
    )

def_movsx :: InstructionDef
def_movsx = defBinaryLVge "movsx" $ \l v -> l .= sext (typeWidth l) v

def_movsxd :: InstructionDef
def_movsxd = defBinaryLVge "movsxd" $ \l v -> l .= sext (typeWidth l) v

def_movzx :: InstructionDef
def_movzx = defBinaryLVge "movzx" $ \l v -> do
  l .= uext (typeWidth l) v

-- The xchng instruction
def_xchg :: InstructionDef
def_xchg = defBinary "xchg" $ \_ f_loc f_loc' -> do
  SomeBV l <- getSomeBVLocation f_loc
  l' <- getBVLocation f_loc' (typeWidth l)
  v  <- get l
  v' <- get l'
  l  .= v'
  l' .= v

-- ** Binary Arithmetic Instructions

exec_adc :: IsLocationBV m n
         => MLocation m (BVType n)
         -> Value m (BVType n)
         -> m ()
exec_adc dst y = do
  -- Get current value stored in destination.
  dst_val <- get dst
  -- Get current value of carry bit
  c <- get cf_loc
  -- Set overflow and arithmetic flags
  of_loc .= sadc_overflows  dst_val y c
  af_loc .= uadc4_overflows dst_val y c
  cf_loc .= uadc_overflows  dst_val y c
  -- Set result value.
  let w = typeWidth dst
  let cbv = mux c (bvLit w 1) (bvLit w 0)
  set_result_value dst (dst_val `bvAdd` y `bvAdd` cbv)

-- | @add@
exec_add :: IsLocationBV m n
         => MLocation m (BVType n)
         -> Value m (BVType n)
         -> m ()
exec_add dst y = do
  -- Get current value stored in destination.
  dst_val <- get dst
  -- Set overflow and arithmetic flags
  of_loc .= sadd_overflows  dst_val y
  af_loc .= uadd4_overflows dst_val y
  cf_loc .= uadd_overflows  dst_val y
  -- Set result value.
  set_result_value dst (dst_val `bvAdd` y)

-- FIXME: we don't need a location, just a value.
exec_cmp :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_cmp dst y = do
  dst_val <- get dst
  -- Set overflow and arithmetic flags
  of_loc .= ssub_overflows  dst_val y
  af_loc .= usub4_overflows dst_val y
  cf_loc .= usub_overflows  dst_val y
  -- Set result value.
  set_result_flags (dst_val `bvSub` y)

exec_dec :: IsLocationBV m n => MLocation m (BVType n) -> m ()
exec_dec dst = do
  dst_val <- get dst
  let v1 = bvLit (bv_width dst_val) 1
  -- Set overflow and arithmetic flags
  of_loc .= ssub_overflows  dst_val v1
  af_loc .= usub4_overflows dst_val v1
  -- no carry flag
  -- Set result value.
  set_result_value dst (dst_val `bvSub` v1)

set_div_flags :: Semantics m => m ()
set_div_flags = do
  set_undefined cf_loc
  set_undefined of_loc
  set_undefined sf_loc
  set_undefined af_loc
  set_undefined pf_loc
  set_undefined zf_loc

do_div :: forall m n
        . (IsLocationBV m n, 1 <= n + n, n <= n + n)
       => MLocation m (BVType n) -- ^ Location to store quotient
       -> MLocation m (BVType n) -- ^ Location to store remainder
       -> Value m (BVType (n+n)) -- ^ Numerator
       -> Value m (BVType n)     -- ^ Denominator
       -> m ()
do_div axr dxr numerator denominator = do
  let n :: NatRepr n
      n = bv_width denominator

  let nn = addNat n n
  let denominator' = uext nn denominator
  q <- bvTrunc n <$> bvQuot numerator denominator'
  r <- bvTrunc n <$> bvRem  numerator denominator'
  axr .= q
  dxr .= r
  set_div_flags

-- | Helper function for @div@ and @idiv@ instructions.
--
-- The difference between @div@ and @idiv@ is whether the primitive
-- operations are signed or not.
--
-- The x86 division instructions are peculiar. A @2n@-bit numerator is
-- read from fixed registers and an @n@-bit quotient and @n@-bit
-- remainder are written to those fixed registers. An exception is
-- raised if the denominator is zero or if the quotient does not fit
-- in @n@ bits.
--
-- Also, results should be rounded towards zero. These operations are
-- called @quot@ and @rem@ in Haskell, whereas @div@ and @mod@ in
-- Haskell round towards negative infinity.
--
-- Source: the x86 documentation for @idiv@, Intel x86 manual volume
-- 2A, page 3-393.

-- | Unsigned (@div@ instruction) and signed (@idiv@ instruction) division.
def_div :: InstructionDef
def_div = defUnaryV "div" $ \d ->
   case bv_width d of
     n | Just Refl <- testEquality n n8  -> do
           num <- get ax
           do_div al ah num d
       | Just Refl <- testEquality n n16 -> do
           dxv <- get dx
           axv <- get ax
           do_div ax  dx (bvCat dxv axv) d
       | Just Refl <- testEquality n n32 -> do
           dxv <- get edx
           axv <- get eax
           do_div eax edx (bvCat dxv axv) d
       | Just Refl <- testEquality n n64 -> do
           dxv <- get rdx
           axv <- get rax
           do_div rax rdx (bvCat dxv axv) d
       | otherwise -> fail "div: Unknown bit width"

def_idiv :: InstructionDef
def_idiv = defUnaryV "idiv" $ \d -> do
  set_div_flags
  case bv_width d of
    n | Just Refl <- testEquality n n8  -> do
           num <- get ax
           (q,r) <- bvSignedQuotRem ByteRepVal num d
           al .= q
           ah .= r
       | Just Refl <- testEquality n n16 -> do
           num <- bvCat <$> get dx <*> get ax
           (q,r) <- bvSignedQuotRem WordRepVal num d
           ax .= q
           dx .= r
       | Just Refl <- testEquality n n32 -> do
           num <- bvCat <$> get edx <*> get eax
           (q,r) <- bvSignedQuotRem DWordRepVal num d
           eax .= q
           edx .= r
       | Just Refl <- testEquality n n64 -> do
           num <- bvCat <$> get rdx <*> get rax
           (q,r) <- bvSignedQuotRem QWordRepVal num d
           rax .= q
           rdx .= r
       | otherwise -> fail "idiv: Unknown bit width"

--  | Execute the halt instruction
--
-- This code assumes that we are not running in kernel mode.
def_hlt :: InstructionDef
def_hlt = defNullary "hlt" $ exception false true (GeneralProtectionException 0)

exec_inc :: IsLocationBV m n => MLocation m (BVType n) -> m ()
exec_inc dst = do
  -- Get current value stored in destination.
  dst_val <- get dst
  let y  = bvLit (bv_width dst_val) 1
  -- Set overflow and arithmetic flags
  of_loc .= sadd_overflows  dst_val y
  af_loc .= uadd4_overflows dst_val y
  -- no cf_loc
  -- Set result value.
  set_result_value dst (dst_val `bvAdd` y)

-- FIXME: is this the right way around?
exec_mul :: forall m n
          . (IsLocationBV m n)
         => Value m (BVType n)
         -> m ()
exec_mul v
  | Just Refl <- testEquality (bv_width v) n8  = do
    r <- go al
    ax .= r
  | Just Refl <- testEquality (bv_width v) n16 = do
    (upper, lower) <- bvSplit <$> go ax
    dx .= upper
    ax .= lower
  | Just Refl <- testEquality (bv_width v) n32 = do
    (upper, lower) <- bvSplit <$> go eax
    edx .= upper
    eax .= lower
  | Just Refl <- testEquality (bv_width v) n64 = do
    (upper, lower) <- bvSplit <$> go rax
    rdx .= upper
    rax .= lower
  | otherwise =
    fail "mul: Unknown bit width"
  where
    go :: (1 <= n+n, n <= n+n)
       => MLocation m (BVType n)
       -> m (Value m (BVType (n + n)))
    go l = do
      v' <- get l
      let sz = addNat (bv_width v) (bv_width v)
          r  = uext sz v' `bvMul` uext sz v -- FIXME: uext here is OK?
          upper_r = fst (bvSplit r) :: Value m (BVType n)
      set_undefined sf_loc
      set_undefined af_loc
      set_undefined pf_loc
      set_undefined zf_loc
      let does_overflow = boolNot (is_zero upper_r)
      of_loc .= does_overflow
      cf_loc .= does_overflow
      pure r

really_exec_imul :: forall m n
                  . (IsLocationBV m n)
                 => Value m (BVType n)
                 -> Value m (BVType n)
                 -> m (Value m (BVType (n + n)))
really_exec_imul v v' = do
  let w = bv_width v
  let sz = addNat w w
  let w_is_pos :: LeqProof 1 n
      w_is_pos = LeqProof
  withLeqProof (leqAdd w_is_pos w) $ do
  withLeqProof (addIsLeq w w) $ do
  let r :: Value m (BVType (n + n))
      r  = sext sz v' .* sext sz v
      (_, lower_r :: Value m (BVType n)) = bvSplit r
  set_undefined af_loc
  set_undefined pf_loc
  set_undefined zf_loc
  sf_loc .= msb lower_r
  let does_overflow = (r .=/=. sext sz lower_r)
  of_loc .= does_overflow
  cf_loc .= does_overflow
  pure r

exec_imul1 :: forall m n. IsLocationBV m n => Value m (BVType n) -> m ()
exec_imul1 v
  | Just Refl <- testEquality (bv_width v) n8  = do
      v' <- get al
      r <- really_exec_imul v v'
      ax .= r
  | Just Refl <- testEquality (bv_width v) n16 = do
      v' <- get ax
      (upper, lower) <- bvSplit <$> really_exec_imul v v'
      dx .= upper
      ax .= lower
  | Just Refl <- testEquality (bv_width v) n32 = do
      v' <- get eax
      (upper, lower) <- bvSplit <$> really_exec_imul v v'
      edx .= upper
      eax .= lower
  | Just Refl <- testEquality (bv_width v) n64 = do
      v' <- get rax
      (upper, lower) <- bvSplit <$> really_exec_imul v v'
      rdx .= upper
      rax .= lower
  | otherwise =
      fail "imul: Unknown bit width"

-- FIXME: clag from exec_mul, exec_imul
exec_imul2_3 :: forall m n n'
              . (IsLocationBV m n, 1 <= n', n' <= n)
             => MLocation m (BVType n) -> Value m (BVType n) -> Value m (BVType n') -> m ()
exec_imul2_3 l v v' = do
  withLeqProof (dblPosIsPos (LeqProof :: LeqProof 1 n)) $ do
  r <- really_exec_imul v (sext (bv_width v) v')
  l .= snd (bvSplit r)

def_imul :: InstructionDef
def_imul = defVariadic "imul"   $ \_ vs ->
  case vs of
    [val] -> do
      SomeBV v <- getSomeBVValue val
      exec_imul1 v
    [loc, val] -> do
      SomeBV l <- getSomeBVLocation loc
      v' <- getSignExtendedValue val (typeWidth l)
      v <- get l
      exec_imul2_3 l v v'
    [loc, val, val'] -> do
      SomeBV l <- getSomeBVLocation loc
      v  <- getBVValue val (typeWidth l)
      SomeBV v' <- getSomeBVValue val'
      Just LeqProof <- return $ testLeq (bv_width v') (bv_width v)
      exec_imul2_3 l v v'
    _ ->
      fail "Impossible number of argument in imul"

-- | Should be equiv to 0 - *l
def_neg :: InstructionDef
def_neg = defUnaryLoc "neg" $ \l -> do
  v <- get l
  cf_loc .= mux (is_zero v) false true
  let r = bvNeg v
      zero = bvLit (bv_width v) 0
  of_loc .= ssub_overflows  zero v
  af_loc .= usub4_overflows zero v
  set_result_value l r

def_sahf :: InstructionDef
def_sahf = defNullary "sahf" $ do
  v <- get ah
  let mk n = bvBit v (bvLit n8 n)
  cf_loc .= mk 0
  pf_loc .= mk 2
  af_loc .= mk 4
  zf_loc .= mk 6
  sf_loc .= mk 7

exec_sbb :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_sbb l v = do
  cf <- get cf_loc
  v0 <- get l
  let w = typeWidth l
  let cbv = mux cf (bvLit w 1) (bvLit w 0)
  let v' = v `bvAdd` cbv
  -- Set overflow and arithmetic flags
  of_loc .= ssbb_overflows v0 v cf
  af_loc .= uadd4_overflows v cbv .||. usub4_overflows v0 v'
  cf_loc .= uadd_overflows v cbv .||. (usub_overflows  v0 v')
  -- Set result value.
  let res = v0 `bvSub` v'
  set_result_flags res
  l .= res

-- FIXME: duplicates subtraction term by calling exec_cmp
exec_sub :: Binop
exec_sub l v = do
  v0 <- get l
  exec_cmp l v -- set flags
  l .= (v0 `bvSub` v)

-- ** Decimal Arithmetic Instructions
-- ** Logical Instructions

-- | And two values together.
exec_and :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_and r y = do
  x <- get r
  let z = x .&. y
  set_bitwise_flags z
  r .= z

exec_or :: Binop
exec_or l v = do
  v' <- get l
  set_undefined af_loc
  of_loc .= false
  cf_loc .= false
  set_result_value l (v' .|. v)

exec_xor :: Binop
exec_xor l v = do
  v0 <- get l
  let r = v0 `bvXor` v
  set_bitwise_flags r
  l .= r

-- ** Shift and Rotate Instructions


really_exec_shift :: (1 <= n', n' <= n, IsLocationBV m n)
                  => MLocation m (BVType n)
                  -> Value m (BVType n')
                     -- Operation for performing the shift.
                     -- Takes value as first argument and shift amount as second arg.
                  -> (Value m (BVType n) -> Value m (BVType n) -> Value m (BVType n))
                     -- Operation for constructing new carry flag "cf" value.
                  -> (Value m (BVType n) -> Value m (BVType n')
                                         -> Value m (BVType n')
                                         -> Value m BoolType)
                     -- Operation for constructing new overflow flag "of" value.
                  -> (Value m (BVType n) -> Value m (BVType n)
                                         -> Value m BoolType
                                         -> Value m BoolType)
                  -> m ()
really_exec_shift l count do_shift mk_cf mk_of = do
  v    <- get l
  -- The intel manual says that the count is masked to give an upper
  -- bound on the time the shift takes, with a mask of 63 in the case
  -- of a 64 bit operand, and 31 in the other cases.
  let nbits =
        case testLeq (bv_width v) n32 of
          Just LeqProof -> 32
          _             -> 64
      count_mask = bvLit (bv_width count) (nbits - 1)
      --
      low_count = count .&. count_mask  -- FIXME: prefer mod?
      r = do_shift v (uext (bv_width v) low_count)

  -- When the count is zero, nothing happens, in particular, no flags change
  unless_ (is_zero low_count) $ do
    let dest_width = bvLit (bv_width low_count) (natValue (bv_width v))

    let new_cf = mk_cf v dest_width low_count
    cf_undef <- make_undefined knownType
    cf_loc .= mux (low_count `bvUlt` dest_width) new_cf cf_undef

    let low1 = bvLit (bv_width low_count) 1

    of_undef <- make_undefined knownType
    of_loc .= mux (low_count .=. low1) (mk_of v r new_cf) of_undef

    set_undefined af_loc
    set_result_value l r

-- FIXME: could be 8 instead of n' here ...
exec_shl :: (1 <= n', n' <= n, IsLocationBV m n)
         => MLocation m (BVType n) -> Value m (BVType n') -> m ()
exec_shl l count = really_exec_shift l count bvShl mk_cf mk_of
  where mk_cf v dest_width low_count = bvBit v (dest_width `bvSub` low_count)
        mk_of _ r new_cf = msb r `boolXor` new_cf

exec_shr :: (1 <= n', n' <= n, IsLocationBV m n)
         => MLocation m (BVType n)
         -> Value m (BVType n') -> m ()
exec_shr l count = really_exec_shift l count bvShr mk_cf mk_of
  where mk_cf v _ low_count = bvBit v (low_count `bvSub` bvLit (bv_width low_count) 1)
        mk_of v _ _         = msb v

-- FIXME: we can factor this out as above, but we need to check the CF
-- for SAR (intel manual says it is only undefined for shl/shr when
-- the shift is >= the bit width.
exec_sar :: (1 <= n', n' <= n, IsLocationBV m n)
         => MLocation m (BVType n) -> Value m (BVType n') -> m ()
exec_sar l count = do
  v    <- get l
  -- The intel manual says that the count is masked to give an upper
  -- bound on the time the shift takes, with a mask of 63 in the case
  -- of a 64 bit operand, and 31 in the other cases.
  let nbits = case testLeq (bv_width v) n32 of
                Just LeqProof -> 32
                Nothing       -> 64
      countMASK = bvLit (bv_width v) (nbits - 1)
      low_count = uext (bv_width v) count .&. countMASK  -- FIXME: prefer mod?
      r = bvSar v low_count

  -- When the count is zero, nothing happens, in particular, no flags change
  unless_ (is_zero low_count) $ do
    let dest_width = bvLit (bv_width low_count) (natValue (bv_width v))
    let new_cf = bvBit v (low_count `bvSub` bvLit (bv_width low_count) 1)

    -- FIXME: correct?  we assume here that we will get the sign bit ...
    cf_loc .= mux (low_count `bvUlt` dest_width) new_cf (msb v)

    ifte_ (low_count .=. bvLit (bv_width low_count) 1)
      (of_loc .= false)
      (set_undefined of_loc)

    set_undefined af_loc
    set_result_value l r

-- FIXME: use really_exec_shift above?
exec_rol :: (1 <= n', n' <= n, IsLocationBV m n)
         => MLocation m (BVType n)
         -> Value m (BVType n')
         -> m ()
exec_rol l count = do
  v    <- get l
  -- The intel manual says that the count is masked to give an upper
  -- bound on the time the shift takes, with a mask of 63 in the case
  -- of a 64 bit operand, and 31 in the other cases.
  let nbits = case testLeq (bv_width v) n32 of
                Just LeqProof -> 32
                _             -> 64
      countMASK = bvLit (bv_width v) (nbits - 1)
      low_count = uext (bv_width v) count .&. countMASK
      -- countMASK is sufficient for 32 and 64 bit operand sizes, but not 16 or
      -- 8, so we need to mask those off again...
      effectiveMASK = bvLit (bv_width v) (natValue (bv_width v) - 1)
      effective = uext (bv_width v) count .&. effectiveMASK
      r = bvRol v effective

  l .= r

  -- When the count is zero only the assignment happens (cf is not changed)
  unless_ (is_zero low_count) $ do
    let new_cf = bvBit r (bvLit (bv_width r) 0)
    cf_loc .= new_cf

    ifte_ (low_count .=. bvLit (bv_width low_count) 1)
          (of_loc .= (msb r `boolXor` new_cf))
          (set_undefined of_loc)

-- FIXME: use really_exec_shift above?
exec_ror :: (1 <= n', n' <= n, IsLocationBV m n)
         => MLocation m (BVType n)
         -> Value m (BVType n')
         -> m ()
exec_ror l count = do
  v    <- get l
  -- The intel manual says that the count is masked to give an upper
  -- bound on the time the shift takes, with a mask of 63 in the case
  -- of a 64 bit operand, and 31 in the other cases.
  let nbits = case testLeq (bv_width v) n32 of
                Just LeqProof -> 32
                Nothing       -> 64
      countMASK = bvLit (bv_width v) (nbits - 1)
      low_count = uext (bv_width v) count .&. countMASK
      -- countMASK is sufficient for 32 and 64 bit operand sizes, but not 16 or
      -- 8, so we need to mask those off again...
      effectiveMASK = bvLit (bv_width v) (natValue (bv_width v) - 1)
      effective = uext (bv_width v) count .&. effectiveMASK
      r = bvRor v effective

  l .= r

  unless_ (is_zero low_count) $ do
    let new_cf = bvBit r (bvLit (bv_width r) (natValue (bv_width r) - 1))
    cf_loc .= new_cf

    ifte_ (low_count .=. bvLit (bv_width low_count) 1)
          (of_loc .= (msb r `boolXor` bvBit r (bvLit (bv_width r) (natValue (bv_width v) - 2))))
          (set_undefined of_loc)

-- ** Bit and Byte Instructions

isRegister :: Location addr tp -> Bool
isRegister (Register _)      = True
isRegister (FullRegister _)  = True
isRegister (MemoryAddr {})   = False
isRegister (ControlReg _)    = True
isRegister (DebugReg _)      = True
isRegister (SegmentReg _)    = True
isRegister (X87ControlReg _) = True
isRegister (X87StackRegister {}) = False

-- return val modulo the size of the register at loc iff loc is a register, otherwise return val
moduloRegSize :: (IsValue v, 1 <= n) => Location addr (BVType n') -> v (BVType n) -> v (BVType n)
moduloRegSize loc val
  | Just Refl <- testEquality (typeWidth loc) n8  = go loc val  7
  | Just Refl <- testEquality (typeWidth loc) n16 = go loc val 15
  | Just Refl <- testEquality (typeWidth loc) n32 = go loc val 31
  | Just Refl <- testEquality (typeWidth loc) n64 = go loc val 63
  | otherwise = val -- doesn't match any of the register sizes
  where go l v maskVal | isRegister l = v .&. bvLit (bv_width v) maskVal -- v mod maskVal
                       | otherwise = v

-- make a bitmask of size 'width' with only the bit at bitPosition set
singleBitMask :: (IsValue v, 1 <= n, 1 <= log_n, log_n <= n) => NatRepr n -> v (BVType log_n) -> v (BVType n)
singleBitMask width bitPosition = bvShl (bvLit width 1) (uext width bitPosition)

exec_bt :: (IsLocationBV m n, 1 <= log_n) => MLocation m (BVType n) -> Value m (BVType log_n) -> m ()
exec_bt base offset = do
  b <- get base
  -- if base is register, take offset modulo 16/32/64 based on reg width
  cf_loc .= bvBit b (moduloRegSize base offset)
  set_undefined of_loc
  set_undefined sf_loc
  set_undefined af_loc
  set_undefined pf_loc

-- for all BT* instructions that modify the checked bit
exec_bt_chg :: (IsLocationBV m n, 1 <= log_n, log_n <= n)
            => (Value m (BVType n) -> Value m (BVType n) -> Value m (BVType n))
            -> MLocation m (BVType n)
            -> Value m (BVType log_n) -> m ()
exec_bt_chg op base offset = do
  exec_bt base offset
  b <- get base
  base .= b `op` singleBitMask (typeWidth base) (moduloRegSize base offset)

exec_btc, exec_btr, exec_bts :: (IsLocationBV m n, 1 <= log_n, log_n <= n) => MLocation m (BVType n) -> Value m (BVType log_n) -> m ()
exec_btc = exec_bt_chg bvXor
exec_btr = exec_bt_chg $ \l r -> l .&. (bvComplement r)
exec_bts = exec_bt_chg (.|.)


exec_bsf :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_bsf r y = do
  zf_loc .= is_zero y
  set_undefined cf_loc
  set_undefined of_loc
  set_undefined sf_loc
  set_undefined af_loc
  set_undefined pf_loc
  r .= bsf y

exec_bsr :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_bsr r y = do
  zf_loc .= is_zero y
  set_undefined cf_loc
  set_undefined of_loc
  set_undefined sf_loc
  set_undefined af_loc
  set_undefined pf_loc
  r .= bsr y

exec_test :: Binop
exec_test l v = do
  v' <- get l
  let r = v' .&. v
  set_bitwise_flags r

def_set_list :: [InstructionDef]
def_set_list =
  defConditionals "set" $ \mnem cc ->
    defUnary mnem $ \_ v -> do
      l <- getBVLocation v n8
      c <- cc
      l .= mux c (bvLit n8 1) (bvLit n8 0)

-- ** Control Transfer Instructions

def_call :: InstructionDef
def_call = defUnary "call" $ \_ v -> do
  -- Push value of next instruction
  old_pc <- get rip
  push addrRepr old_pc
  -- Set IP
  tgt <- getJumpTarget v
  rip .= tgt

-- | Conditional jumps
def_jcc_list :: [InstructionDef]
def_jcc_list =
  defConditionals "j" $ \mnem cc ->
    defUnary mnem $ \_ v -> do
      a <- cc
      when_ a $ do
        old_pc <- get rip
        off <- getBVValue v knownNat
        rip .= old_pc `bvAdd` off

def_jmp :: InstructionDef
def_jmp = defUnary "jmp" $ \_ v -> do
  tgt <- getJumpTarget v
  rip .= tgt

def_ret :: InstructionDef
def_ret = defVariadic "ret"    $ \_ vs ->
  case vs of
    [] -> do
      -- Pop IP and jump to it.
      next_ip <- pop addrRepr
      rip .= next_ip
    [F.WordImm off] -> do
      -- Pop IP and adjust stack pointer.
      next_ip <- pop addrRepr
      modify rsp (bvAdd (bvLit n64 (toInteger off)))
      -- Set IP
      rip .= next_ip
    _ ->
      fail "Unexpected number of args to ret"

-- ** String Instructions

-- | MOVS/MOVSB Move string/Move byte string
-- MOVS/MOVSW Move string/Move word string
-- MOVS/MOVSD Move string/Move doubleword string

-- FIXME: probably doesn't work for 32 bit address sizes
-- arguments are only for the size, they are fixed at rsi/rdi
exec_movs :: (Semantics m, 1 <= w)
          => Bool -- Flag indicating if RepPrefix appeared before instruction
          -> NatRepr w -- Number of bytes to move at a time.
          -> m ()
exec_movs False w = do
  let bytesPerOp = bvLit n64 (natValue w)
  let repr = BVMemRepr w LittleEndian
  -- The direction flag indicates post decrement or post increment.
  df <- get df_loc
  src  <- get rsi
  dest <- get rdi
  v' <- get $ MemoryAddr src repr
  MemoryAddr dest repr .= v'

  rsi .= mux df (src  .- bytesPerOp) (src  .+ bytesPerOp)
  rdi .= mux df (dest .- bytesPerOp) (dest .+ bytesPerOp)
exec_movs True w = do
    -- FIXME: aso modifies this
  let count_reg = rcx
      bytesPerOp = natValue w
      bytesPerOpv = bvLit n64 bytesPerOp
  -- The direction flag indicates post decrement or post increment.
  df <- get df_loc
  src   <- get rsi
  dest  <- get rdi
  count <- get count_reg
  let total_bytes = count .* bytesPerOpv
  -- FIXME: we might need direction for overlapping regions
  count_reg .= bvLit n64 (0::Integer)
  memcopy bytesPerOp count src dest df
  rsi .= mux df (src   .- total_bytes) (src   .+ total_bytes)
  rdi .= mux df (dest  .- total_bytes) (dest  .+ total_bytes)

def_movs :: InstructionDef
def_movs = defBinary "movs" $ \pfx loc _ -> do
  case loc of
    F.Mem8 F.Addr_64{} ->
      exec_movs (pfx == F.RepPrefix) (knownNat :: NatRepr 1)
    F.Mem16 F.Addr_64{} ->
      exec_movs (pfx == F.RepPrefix) (knownNat :: NatRepr 2)
    F.Mem32 F.Addr_64{} ->
      exec_movs (pfx == F.RepPrefix) (knownNat :: NatRepr 4)
    F.Mem64 F.Addr_64{} ->
      exec_movs (pfx == F.RepPrefix) (knownNat :: NatRepr 8)
    _ -> fail "Bad argument to movs"

-- FIXME: can also take rep prefix
-- FIXME: we ignore the aso here.
-- | CMPS/CMPSB Compare string/Compare byte string
-- CMPS/CMPSW Compare string/Compare word string
-- CMPS/CMPSD Compare string/Compare doubleword string

exec_cmps :: Semantics m
          => Bool
          -> RepValSize w
          -> m ()
exec_cmps repz_pfx rval = repValHasSupportedWidth rval $ do
  let repr = repValSizeMemRepr rval
  -- The direction flag indicates post decrement or post increment.
  df <- get df_loc
  v_rsi <- get rsi
  v_rdi <- get rdi
  let bytesPerOp = memReprBytes repr
  let bytesPerOp' = bvLit n64 bytesPerOp
  if repz_pfx then do
    count <- get rcx
    unless_ (count .=. bvKLit 0) $ do
      nsame <- memcmp bytesPerOp count v_rsi v_rdi df
      let equal = (nsame .=. count)
          nwordsSeen = mux equal count (count `bvSub` (nsame `bvAdd` bvKLit 1))

      -- we need to set the flags as if the last comparison was done, hence this.
      let lastWordBytes = (nwordsSeen `bvSub` bvKLit 1) `bvMul` bytesPerOp'
          lastSrc  = mux df (v_rsi `bvSub` lastWordBytes) (v_rsi `bvAdd` lastWordBytes)
          lastDest = mux df (v_rdi `bvSub` lastWordBytes) (v_rdi `bvAdd` lastWordBytes)

      v' <- get $ MemoryAddr lastDest repr
      exec_cmp (MemoryAddr lastSrc repr) v' -- FIXME: right way around?

      -- we do this to make it obvious so repz cmpsb ; jz ... is clear
      zf_loc .= equal
      let nbytesSeen = nwordsSeen `bvMul` bytesPerOp'

      rsi .= mux df (v_rsi `bvSub` nbytesSeen) (v_rsi `bvAdd` nbytesSeen)
      rdi .= mux df (v_rdi `bvSub` nbytesSeen) (v_rdi `bvAdd` nbytesSeen)
      rcx .= (count .- nwordsSeen)
   else do
     v' <- get $ MemoryAddr v_rdi repr
     exec_cmp (MemoryAddr   v_rsi repr) v' -- FIXME: right way around?
     rsi .= mux df (v_rsi  `bvSub` bytesPerOp') (v_rsi `bvAdd` bytesPerOp')
     rdi .= mux df (v_rdi  `bvSub` bytesPerOp') (v_rdi `bvAdd` bytesPerOp')


def_cmps :: InstructionDef
def_cmps = defBinary "cmps" $ \pfx loc _ -> do
  Some rval <-
    case loc of
      F.Mem8 F.Addr_64{} -> do
        pure $ Some ByteRepVal
      F.Mem16 F.Addr_64{} -> do
        pure $ Some WordRepVal
      F.Mem32 F.Addr_64{} -> do
        pure $ Some DWordRepVal
      F.Mem64 F.Addr_64{} -> do
        pure $ Some QWordRepVal
      _ -> fail "Bad argument to cmps"
  exec_cmps (pfx == F.RepZPrefix) rval

-- SCAS/SCASB Scan string/Scan byte string
-- SCAS/SCASW Scan string/Scan word string
-- SCAS/SCASD Scan string/Scan doubleword string

xaxValLoc :: RepValSize w -> Location a (BVType w)
xaxValLoc ByteRepVal  = al
xaxValLoc WordRepVal  = ax
xaxValLoc DWordRepVal = eax
xaxValLoc QWordRepVal = rax

-- The arguments to this are always rax/QWORD PTR es:[rdi], so we only
-- need the args for the size.
exec_scas :: Semantics m
          => Bool -- Flag indicating if RepZPrefix appeared before instruction
          -> Bool -- Flag indicating if RepNZPrefix appeared before instruction
          -> RepValSize n
          -> m ()
exec_scas True True _val_loc = error "Can't have both Z and NZ prefix"
-- single operation case
exec_scas False False rep = repValHasSupportedWidth rep $ do
  df <- get df_loc
  v_rdi <- get rdi
  v_rax <- get (xaxValLoc rep)
  let memRepr = repValSizeMemRepr rep
  exec_cmp (MemoryAddr v_rdi memRepr) v_rax  -- FIXME: right way around?
  let bytesPerOp = mux df (bvLit n64 (negate (memReprBytes memRepr)))
                          (bvLit n64 (memReprBytes memRepr))
  rdi   .= v_rdi `bvAdd` bytesPerOp
-- repz or repnz prefix set
exec_scas _repz_pfx repnz_pfx rep = repValHasSupportedWidth rep $ do
  let mrepr = repValSizeMemRepr rep
  let val_loc = xaxValLoc rep
  -- Get the direction flag -- it will be used to determine whether to add or subtract at each step.
  -- If the flag is zero, then the register is incremented, otherwise it is incremented.
  df    <- get df_loc

  -- Get value that we are using in comparison
  v_rax <- get val_loc

  --  Get the starting address for the comparsions
  v_rdi <- get rdi
  -- Get maximum number of times to execute instruction
  count <- get rcx
  unless_ (count .=. bvKLit 0) $ do

    count' <- rep_scas repnz_pfx df rep v_rax v_rdi count

    -- Get number of bytes each comparison will use
    let bytesPerOp = memReprBytes mrepr
    -- Get multiple of each element (negated for direction flag
    let bytePerOpLit = mux df (bvKLit (negate bytesPerOp)) (bvKLit bytesPerOp)

    -- Count the number of bytes seen.
    let nBytesSeen    = (count `bvSub` count') `bvMul` bytePerOpLit

    let lastWordBytes = nBytesSeen `bvSub` bytePerOpLit

    exec_cmp (MemoryAddr (v_rdi `bvAdd` lastWordBytes) mrepr) v_rax

    rdi .= v_rdi `bvAdd` nBytesSeen
    rcx .= count'

def_scas :: InstructionDef
def_scas = defBinary "scas" $ \pfx loc loc' -> do
  Some rval <-
    case (loc, loc') of
      (F.ByteReg  F.AL,  F.Mem8  (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement)) -> do
        pure $ Some ByteRepVal
      (F.WordReg  F.AX,  F.Mem16 (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement)) -> do
        pure $ Some WordRepVal
      (F.DWordReg F.EAX, F.Mem32 (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement)) -> do
        pure $ Some DWordRepVal
      (F.QWordReg F.RAX, F.Mem64 (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement)) -> do
        pure $ Some QWordRepVal
      _ -> error $ "scas given bad addrs " ++ show (loc, loc')
  exec_scas (pfx == F.RepZPrefix) (pfx == F.RepNZPrefix) rval

-- LODS/LODSB Load string/Load byte string
-- LODS/LODSW Load string/Load word string
-- LODS/LODSD Load string/Load doubleword string
exec_lods :: (Semantics m, 1 <= w)
          => Bool -- ^ Flag indicating if RepPrefix appeared before instruction
          -> RepValSize w
          -> m ()
exec_lods False rep = do
  let mrepr = repValSizeMemRepr rep
  -- The direction flag indicates post decrement or post increment.
  df   <- get df_loc
  src  <- get rsi
  let szv     = bvLit n64 (memReprBytes mrepr)
      neg_szv = bvLit n64 (negate (memReprBytes mrepr))
  v <- get (MemoryAddr src mrepr)
  (xaxValLoc rep) .= v
  rsi .= src .+ mux df neg_szv szv
exec_lods True _rep = error "exec_lods: rep prefix support not implemented"

def_lods :: InstructionDef
def_lods = defBinary "lods" $ \pfx loc loc' -> do
  case (loc, loc') of
    (F.Mem8  (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement), F.ByteReg  F.AL) -> do
      exec_lods (pfx == F.RepPrefix) ByteRepVal
    (F.Mem16 (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement), F.WordReg  F.AX) -> do
      exec_lods (pfx == F.RepPrefix) WordRepVal
    (F.Mem32 (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement), F.DWordReg F.EAX) -> do
      exec_lods (pfx == F.RepPrefix) DWordRepVal
    (F.Mem64 (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement), F.QWordReg F.RAX) -> do
      exec_lods (pfx == F.RepPrefix) QWordRepVal
    _ -> error $ "lods given bad arguments " ++ show (loc, loc')

def_lodsx :: (1 <= elsz) => String -> NatRepr elsz -> InstructionDef
def_lodsx mnem elsz = defNullaryPrefix mnem $ \pfx -> do
  let rep = pfx == F.RepPrefix
  case natValue elsz of
    8  -> exec_lods rep ByteRepVal
    16 -> exec_lods rep WordRepVal
    32 -> exec_lods rep DWordRepVal
    64 -> exec_lods rep QWordRepVal
    _  -> error $ "lodsx given bad size " ++ show (natValue elsz)

-- | STOS/STOSB Store string/Store byte string
-- STOS/STOSW Store string/Store word string
-- STOS/STOSD Store string/Store doubleword string
exec_stos :: (Semantics m, 1 <= w)
          => Bool -- Flag indicating if RepPrefix appeared before instruction
          -> RepValSize w
          -> m ()
exec_stos False rep = do
  let mrepr = repValSizeMemRepr rep
  -- The direction flag indicates post decrement or post increment.
  df   <- get df_loc
  dest <- get rdi
  v    <- get (xaxValLoc rep)
  let neg_szv = bvLit n64 (negate (memReprBytes mrepr))
  let szv     = bvLit n64 (memReprBytes mrepr)
  MemoryAddr dest mrepr .= v
  rdi .= dest .+ mux df neg_szv szv
exec_stos True rep = do
  let mrepr = repValSizeMemRepr rep
  -- The direction flag indicates post decrement or post increment.
  df   <- get df_loc
  dest <- get rdi
  v    <- get (xaxValLoc rep)
  let szv = bvLit n64 (memReprBytes mrepr)
  count <- get rcx
  let nbytes     = count `bvMul` szv
  memset count v dest df
  rdi .= mux df (dest .- nbytes) (dest .+ nbytes)
  rcx .= bvKLit 0

def_stos :: InstructionDef
def_stos = defBinary "stos" $ \pfx loc loc' -> do
  case (loc, loc') of
    (F.Mem8  (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement), F.ByteReg  F.AL) -> do
      exec_stos (pfx == F.RepPrefix) ByteRepVal
    (F.Mem16 (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement), F.WordReg  F.AX) -> do
      exec_stos (pfx == F.RepPrefix) WordRepVal
    (F.Mem32 (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement), F.DWordReg F.EAX) -> do
      exec_stos (pfx == F.RepPrefix) DWordRepVal
    (F.Mem64 (F.Addr_64 F.ES (Just F.RDI) Nothing F.NoDisplacement), F.QWordReg F.RAX) -> do
      exec_stos (pfx == F.RepPrefix) QWordRepVal
    _ -> error $ "stos given bad arguments " ++ show (loc, loc')

-- REP        Repeat while ECX not zero
-- REPE/REPZ  Repeat while equal/Repeat while zero
-- REPNE/REPNZ Repeat while not equal/Repeat while not zero

-- ** I/O Instructions
-- ** Enter and Leave Instructions

exec_leave :: Semantics m => m ()
exec_leave = do
  bp_v <- get rbp
  rsp .= bp_v
  bp_v' <- pop addrRepr
  rbp .= bp_v'

-- ** Flag Control (EFLAG) Instructions

-- ** Segment Register Instructions
-- ** Miscellaneous Instructions

def_lea :: InstructionDef
def_lea = defBinary "lea" $ \_ loc (F.VoidMem ar) -> do
  SomeBV l <- getSomeBVLocation loc
  -- ensure that the location is at most 64 bits
  Just LeqProof <- return $ testLeq (typeWidth l) n64
  v <- getBVAddress ar
  l .= bvTrunc (typeWidth l) v

-- ** Random Number Generator Instructions
-- ** BMI1, BMI2

-- * X86 FPU instructions

type FPUnop  = forall flt m.
  Semantics m => FloatInfoRepr flt -> MLocation m (FloatType flt) -> m ()
type FPUnopV = forall flt m.
  Semantics m => FloatInfoRepr flt -> Value m (FloatType flt) -> m ()
type FPBinop = forall flt_d flt_s m.
  Semantics m => FloatInfoRepr flt_d -> MLocation m (FloatType flt_d) ->
                 FloatInfoRepr flt_s -> Value m (FloatType flt_s) -> m ()

-- ** Data transfer instructions

-- | FLD Load floating-point value
exec_fld :: FPUnopV
exec_fld fir v = x87Push (fpCvt fir X86_80FloatRepr v)

-- | FST Store floating-point value
exec_fst :: FPUnop
exec_fst fir l = do
  v <- get (X87StackRegister 0)
  set_undefined c0_loc
  set_undefined c2_loc
  set_undefined c3_loc
  -- TODO: The value assigned to c1_loc seems wrong
  -- The bit is only set if the floating-point inexact exception is thrown.
  -- It should be set to 0 is if a stack underflow occurred.
  c1_loc .= fpCvtRoundsUp X86_80FloatRepr fir v

  l .= fpCvt X86_80FloatRepr fir v

-- | FSTP Store floating-point value
def_fstp :: InstructionDef
def_fstp = defUnaryFPL "fstp"   $ \fir l -> do
  exec_fst fir l
  x87Pop

-- FILD Load integer
-- FIST Store integer
-- FISTP1 Store integer and pop
-- FBLD Load BCD
-- FBSTP Store BCD and pop
-- FXCH Exchange registers
-- FCMOVE Floating-point conditional   move if equal
-- FCMOVNE Floating-point conditional  move if not equal
-- FCMOVB Floating-point conditional   move if below
-- FCMOVBE Floating-point conditional  move if below or equal
-- FCMOVNB Floating-point conditional  move if not below
-- FCMOVNBE Floating-point conditional move if not below or equal
-- FCMOVU Floating-point conditional   move if unordered
-- FCMOVNU Floating-point conditional  move if not unordered

-- ** Basic arithmetic instructions

fparith :: Semantics m =>
           (forall flt
            . FloatInfoRepr flt
            -> Value m (FloatType flt)
            -> Value m (FloatType flt)
            -> Value m (FloatType flt))
           -> (forall flt
               . FloatInfoRepr flt
               -> Value m (FloatType flt)
               -> Value m (FloatType flt)
               -> Value m BoolType)
           -> FloatInfoRepr flt_d
           -> MLocation m (FloatType flt_d)
           -> FloatInfoRepr flt_s
           -> Value m (FloatType flt_s)
           -> m ()
fparith op opRoundedUp fir_d l fir_s v = do
  let up_v = fpCvt fir_s fir_d v
  v' <- get l
  set_undefined c0_loc
  c1_loc .= opRoundedUp fir_d v' up_v
  set_undefined c2_loc
  set_undefined c3_loc
  l .= op fir_d v' up_v

-- | FADD Add floating-point
exec_fadd :: FPBinop
exec_fadd = fparith fpAdd fpAddRoundedUp

-- FADDP Add floating-point and pop
-- FIADD Add integer

-- | FSUB Subtract floating-point
exec_fsub :: FPBinop
exec_fsub = fparith fpSub fpSubRoundedUp

-- | FSUBP Subtract floating-point and pop
exec_fsubp :: FPBinop
exec_fsubp fir_d l fir_s v = exec_fsub fir_d l fir_s v >> x87Pop

-- FISUB Subtract integer

-- | FSUBR Subtract floating-point reverse
exec_fsubr :: FPBinop
exec_fsubr = fparith (reverseOp fpSub) (reverseOp fpSubRoundedUp)
  where
    reverseOp f = \fir x y -> f fir y x

-- | FSUBRP Subtract floating-point reverse and pop
exec_fsubrp :: FPBinop
exec_fsubrp fir_d l fir_s v = exec_fsubr fir_d l fir_s v >> x87Pop

-- FISUBR Subtract integer reverse

-- FIXME: we could factor out commonalities between this and fadd
-- | FMUL Multiply floating-point
exec_fmul :: FPBinop
exec_fmul = fparith fpMul fpMulRoundedUp

-- FMULP Multiply floating-point and pop
-- FIMUL Multiply integer
-- FDIV Divide floating-point
-- FDIVP Divide floating-point and pop
-- FIDIV Divide integer
-- FDIVR Divide floating-point reverse
-- FDIVRP Divide floating-point reverse and pop
-- FIDIVR Divide integer reverse
-- FPREM Partial remainder
-- FPREM1 IEEE Partial remainder
-- FABS Absolute value
-- FCHS Change sign
-- FRNDINT Round to integer
-- FSCALE Scale by power of two
-- FSQRT Square root
-- FXTRACT Extract exponent and significand

-- ** Comparison instructions

-- FCOM Compare floating-point
-- FCOMP Compare floating-point and pop
-- FCOMPP Compare floating-point and pop twice
-- FUCOM Unordered compare floating-point
-- FUCOMP Unordered compare floating-point and pop
-- FUCOMPP Unordered compare floating-point and pop twice
-- FICOM Compare integer
-- FICOMP Compare integer and pop
-- FCOMI Compare floating-point and set EFLAGS
-- FUCOMI Unordered compare floating-point and set EFLAGS
-- FCOMIP Compare floating-point, set EFLAGS, and pop
-- FUCOMIP Unordered compare floating-point, set EFLAGS, and pop
-- FTST Test floating-point (compare with 0.0)
-- FXAM Examine floating-point

-- ** Transcendental instructions

-- FSIN Sine
-- FCOS Cosine
-- FSINCOS Sine and cosine
-- FPTAN Partial tangent
-- FPATAN Partial arctangent
-- F2XM1 2x − 1
-- FYL2X y∗log2x
-- FYL2XP1 y∗log2(x+1)

-- ** Load constant instructions

-- FLD1 Load +1.0
-- FLDZ Load +0.0
-- FLDPI Load π
-- FLDL2E Load log2e
-- FLDLN2 Load loge2
-- FLDL2T Load log210
-- FLDLG2 Load log102


-- ** x87 FPU control instructions

-- FINCSTP Increment FPU register stack pointer
-- FDECSTP Decrement FPU register stack pointer
-- FFREE Free floating-point register
-- FINIT Initialize FPU after checking error conditions
-- FNINIT Initialize FPU without checking error conditions
-- FCLEX Clear floating-point exception flags after checking for error conditions
-- FNCLEX Clear floating-point exception flags without checking for error conditions
-- FSTCW Store FPU control word after checking error conditions

-- | FNSTCW Store FPU control word without checking error conditions
def_fnstcw :: InstructionDef
def_fnstcw = defUnary "fnstcw" $ \_ loc -> do
  case loc of
    F.Mem16 f_addr -> do
      addr <- getBVAddress f_addr
      set_undefined c0_loc
      set_undefined c1_loc
      set_undefined c2_loc
      set_undefined c3_loc
      fnstcw addr
    _ -> fail $ "fnstcw given bad argument " ++ show loc

-- FLDCW Load FPU control word
-- FSTENV Store FPU environment after checking error conditions
-- FNSTENV Store FPU environment without checking error conditions
-- FLDENV Load FPU environment
-- FSAVE Save FPU state after checking error conditions
-- FNSAVE Save FPU state without checking error conditions
-- FRSTOR Restore FPU state
-- FSTSW Store FPU status word after checking error conditions
-- FNSTSW Store FPU status word without checking error conditions
-- WAIT/FWAIT Wait for FPU
-- FNOP FPU no operation

-- * X87 FPU and SIMD State Management Instructions

-- FXSAVE Save x87 FPU and SIMD state
-- FXRSTOR Restore x87 FPU and SIMD state


-- * MMX Instructions

-- ** MMX Data Transfer Instructions

exec_movd, exec_movq :: (IsLocationBV m n, 1 <= n')
                     => MLocation m (BVType n)
                     -> Value m (BVType n')
                     -> m ()
exec_movd l v
  | Just LeqProof <- testLeq  (typeWidth l) (bv_width v) = l .= bvTrunc (typeWidth l) v
  | Just LeqProof <- testLeq  (bv_width v) (typeWidth l) = l .=    uext (typeWidth l) v
  | otherwise = fail "movd: Unknown bit width"
exec_movq = exec_movd


-- ** MMX Conversion Instructions

-- PACKSSWB Pack words into bytes with signed saturation
-- PACKSSDW Pack doublewords into words with signed saturation
-- PACKUSWB Pack words into bytes with unsigned saturation

punpck :: (IsLocationBV m n, 1 <= o)
       => (([Value m (BVType o)], [Value m (BVType o)]) -> [Value m (BVType o)])
       -> NatRepr o -> MLocation m (BVType n) -> Value m (BVType n) -> m ()
punpck f pieceSize l v = do
  v0 <- get l
  let dSplit = f $ splitHalf $ bvVectorize pieceSize v0
      sSplit = f $ splitHalf $ bvVectorize pieceSize v
      r = bvUnvectorize (typeWidth l) $ concat $ zipWith (\a b -> [b, a]) dSplit sSplit
  l .= r
  where splitHalf :: [a] -> ([a], [a])
        splitHalf xs = splitAt ((length xs + 1) `div` 2) xs

punpckh, punpckl :: (IsLocationBV m n, 1 <= o) => NatRepr o -> MLocation m (BVType n) -> Value m (BVType n) -> m ()
punpckh = punpck fst
punpckl = punpck snd

exec_punpckhbw, exec_punpckhwd, exec_punpckhdq, exec_punpckhqdq :: Binop
exec_punpckhbw  = punpckh n8
exec_punpckhwd  = punpckh n16
exec_punpckhdq  = punpckh n32
exec_punpckhqdq = punpckh n64

exec_punpcklbw, exec_punpcklwd, exec_punpckldq, exec_punpcklqdq :: Binop
exec_punpcklbw  = punpckl n8
exec_punpcklwd  = punpckl n16
exec_punpckldq  = punpckl n32
exec_punpcklqdq = punpckl n64


-- ** MMX Packed Arithmetic Instructions

exec_paddb :: Binop
exec_paddb l v = do
  v0 <- get l
  l .= vectorize2 n8 bvAdd v0 v

exec_paddw :: Binop
exec_paddw l v = do
  v0 <- get l
  l .= vectorize2 n16 bvAdd v0 v

exec_paddd :: Binop
exec_paddd l v = do
  v0 <- get l
  l .= vectorize2 n32 bvAdd v0 v

-- PADDSB Add packed signed byte integers with signed saturation
-- PADDSW Add packed signed word integers with signed saturation
-- PADDUSB Add packed unsigned byte integers with unsigned saturation
-- PADDUSW Add packed unsigned word integers with unsigned saturation

exec_psubb :: Binop
exec_psubb l v = do
  v0 <- get l
  l .= vectorize2 n8 bvSub v0 v

exec_psubw :: Binop
exec_psubw l v = do
  v0 <- get l
  l .= vectorize2 n16 bvSub v0 v

exec_psubd :: Binop
exec_psubd l v = do
  v0 <- get l
  l .= vectorize2 n32 bvSub v0 v

-- PSUBSB Subtract packed signed byte integers with signed saturation
-- PSUBSW Subtract packed signed word integers with signed saturation
-- PSUBUSB Subtract packed unsigned byte integers with unsigned saturation
-- PSUBUSW Subtract packed unsigned word integers with unsigned saturation
-- PMULHW Multiply packed signed word integers and store high result
-- PMULLW Multiply packed signed word integers and store low result
-- PMADDWD Multiply and add packed word integers


-- ** MMX Comparison Instructions

-- replace pairs with 0xF..F if `op` returns true, otherwise 0x0..0
pcmp :: (IsLocationBV m n, 1 <= o)
     => (Value m (BVType o) -> Value m (BVType o) -> Value m BoolType)
     -> NatRepr o
     -> MLocation m (BVType n) -> Value m (BVType n) -> m ()
pcmp op sz l v = do
  v0 <- get l
  l .= vectorize2 sz chkHighLow v0 v
  where chkHighLow d s = mux (d `op` s)
                             (bvLit (bv_width d) (negate 1))
                             (bvLit (bv_width d) 0)

exec_pcmpeqb, exec_pcmpeqw, exec_pcmpeqd  :: Binop
exec_pcmpeqb = pcmp (.=.) n8
exec_pcmpeqw = pcmp (.=.) n16
exec_pcmpeqd = pcmp (.=.) n32

exec_pcmpgtb, exec_pcmpgtw, exec_pcmpgtd  :: Binop
exec_pcmpgtb = pcmp (flip bvSlt) n8
exec_pcmpgtw = pcmp (flip bvSlt) n16
exec_pcmpgtd = pcmp (flip bvSlt) n32


-- ** MMX Logical Instructions

exec_pand :: Binop
exec_pand l v = do
  v0 <- get l
  l .= v0 .&. v

exec_pandn :: Binop
exec_pandn l v = do
  v0 <- get l
  l .= bvComplement v0 .&. v

exec_por :: Binop
exec_por l v = do
  v0 <- get l
  l .= v0 .|. v

exec_pxor :: Binop
exec_pxor l v = do
  v0 <- get l
  l .= v0 `bvXor` v


-- ** MMX Shift and Rotate Instructions

-- | PSLLW Shift packed words left logical
-- PSLLD Shift packed doublewords left logical
-- PSLLQ Shift packed quadword left logical

def_psllx :: (1 <= elsz) => String -> NatRepr elsz -> InstructionDef
def_psllx mnem elsz = defBinaryLVpoly mnem $ \l count -> do
  lv <- get l
  let ls  = bvVectorize elsz lv
      -- This is somewhat tedious: we want to make sure that we don't
      -- truncate e.g. 2^31 to 0, so we saturate if the size is over
      -- the number of bits we want to shift.  We can always fit the
      -- width into count bits (assuming we are passed 16, 32, or 64).
      nbits   = bvLit (bv_width count) (natValue elsz)
      countsz = case testNatCases (bv_width count) elsz of
                  NatCaseLT LeqProof -> uext' elsz count
                  NatCaseEQ          -> count
                  NatCaseGT LeqProof -> bvTrunc' elsz count

      ls' = map (\y -> mux (bvUlt count nbits) (bvShl y countsz) (bvLit elsz 0)) ls

  l .= bvUnvectorize (typeWidth l) ls'

-- PSRLW Shift packed words right logical
-- PSRLD Shift packed doublewords right logical
-- PSRLQ Shift packed quadword right logical
-- PSRAW Shift packed words right arithmetic
-- PSRAD Shift packed doublewords right arithmetic


-- ** MMX State Management Instructions

-- EMMS Empty MMX state


-- * SSE Instructions
-- ** SSE SIMD Single-Precision Floating-Point Instructions
-- *** SSE Data Transfer Instructions

def_movsd :: InstructionDef
def_movsd = defBinary "movsd" $ \_ v1 v2 -> do
  case (v1, v2) of
    -- If source is an XMM register then we will leave high order bits alone.
    (F.XMMReg dest, F.XMMReg src) -> do
      vLow <- get (xmm_low64 src)
      xmm_low64 dest .= vLow
    (F.Mem128 src_addr, F.XMMReg src) -> do
      dest <- qwordLoc src_addr
      vLow <- get (xmm_low64 src)
      dest .= vLow
    -- If destination is an XMM register and source is memory, then zero out
    -- high order bits.
    (F.XMMReg dest, F.Mem128 src_addr) -> do
      v' <- readQWord src_addr
      xmm_loc dest .= uext n128 v'
    _ ->
      fail $ "Unexpected arguments in FlexdisMatcher.movsd: " ++ show v1 ++ ", " ++ show v2

-- Semantics for SSE movss instruction
def_movss :: InstructionDef
def_movss = defBinary "movss" $ \_ v1 v2 -> do
  case (v1, v2) of
    -- If source is an XMM register then we will leave high order bits alone.
    (F.XMMReg dest, F.XMMReg src) -> do
      vLow <- get (xmm_low32 src)
      xmm_low32 dest .= vLow
    (F.Mem128 f_addr, F.XMMReg src) -> do
      dest <- dwordLoc f_addr
      vLow <- get (xmm_low32 src)
      dest .= vLow
    -- If destination is an XMM register and source is memory, then zero out
    -- high order bits.
    (F.XMMReg dest, F.Mem128 src_addr) -> do
      vLoc <- readDWord src_addr
      xmm_loc dest .= uext n128 vLoc
    _ ->
      fail $ "Unexpected arguments in FlexdisMatcher.movss: " ++ show v1 ++ ", " ++ show v2

def_pshufb :: InstructionDef
def_pshufb = defBinary "pshufb" $ \_ f_d f_s -> do
  case (f_d, f_s) of
    (F.XMMReg d, F.XMMReg s) -> do
      d_val  <- get $ xmm_loc d
      s_val  <- get $ xmm_loc s
      r <- pshufb SIMD_128 d_val s_val
      xmm_loc d .= r
    _ -> do
      fail $ "pshufb only supports 2 XMM registers as arguments."

-- MOVAPS Move four aligned packed single-precision floating-point values between XMM registers or between and XMM register and memory
def_movaps :: InstructionDef
def_movaps = defBinaryXMMV "movaps" $ \l v -> l .= v

def_movups :: InstructionDef
def_movups = defBinaryXMMV "movups" $ \l v -> l .= v

-- MOVHPS Move two packed single-precision floating-point values to an from the high quadword of an XMM register and memory
def_movhlps :: InstructionDef
def_movhlps = defBinary "movhlps" $ \_ x y -> do
  case (x, y) of
    (F.XMMReg dst, F.XMMReg src) -> do
      src_val <- get $ xmm_high64 src
      xmm_low64 dst .= src_val
    _ -> fail "Unexpected operands."

def_movhps :: InstructionDef
def_movhps = defBinary "movhps" $ \_ x y -> do
  case (x, y) of
    -- Move high qword of src to dst.
    (F.Mem64 dst_addr, F.XMMReg src) -> do
      src_val <- get $ xmm_high64 src
      dst <- qwordLoc dst_addr
      dst .= src_val
    -- Move qword at src to high qword of dst.
    (F.XMMReg dst, F.Mem64 src_addr) -> do
      src_val <- readQWord src_addr
      xmm_high64 dst .= src_val
    _ -> fail "Unexpected operands."

-- MOVLPS Move two packed single-precision floating-point values to an from the low quadword of an XMM register and memory

def_movlhps :: InstructionDef
def_movlhps = defBinary "movlhps" $ \_ x y -> do
  case (x, y) of
    (F.XMMReg dst, F.XMMReg src) -> do
      src_val <- get $ xmm_low64 src
      xmm_high64 dst .= src_val
    _ -> fail "Unexpected operands."

def_movlps :: InstructionDef
def_movlps = defBinary "movlps" $ \_ x y -> do
  case (x, y) of
    -- Move low qword of src to dst.
    (F.Mem64 dst_addr, F.XMMReg src) -> do
      dst <- qwordLoc dst_addr
      src_val <- get $ xmm_low64 src
      dst .= src_val
    -- Move qword at src to low qword of dst.
    (F.XMMReg dst, F.Mem64 src_addr) -> do
      src_val <- readQWord src_addr
      xmm_low64 dst .= src_val
    _ -> fail "Unexpected operands."

-- *** SSE Packed Arithmetic Instructions

-- | This evaluates an instruction that takes xmm and xmm/m64 arguments,
-- and applies a function that updates the low 64-bits of the first argument.
def_xmm_ss :: String
              -- ^ Instruction mnemonic
           -> (forall v . IsValue v
               => v (FloatType SingleFloat)
               -> v (FloatType SingleFloat)
               -> v (FloatType SingleFloat))
              -- ^ Binary operation
           -> InstructionDef
def_xmm_ss mnem f =
  defBinary mnem $ \_ loc val -> do
    d <- getXMM loc
    y <- get =<< getXMM_mr_low32 val
    modify (xmm_low32 d) $ \x -> f x y

-- ADDSS Add scalar single-precision floating-point values
def_addss :: InstructionDef
def_addss = def_xmm_ss "addss" $ fpAdd SingleFloatRepr

-- SUBSS Subtract scalar single-precision floating-point values
def_subss :: InstructionDef
def_subss = def_xmm_ss "subss" $ fpSub SingleFloatRepr

-- MULSS Multiply scalar single-precision floating-point values
def_mulss :: InstructionDef
def_mulss = def_xmm_ss "mulss" $ fpMul SingleFloatRepr

-- | DIVSS Divide scalar single-precision floating-point values
def_divss :: InstructionDef
def_divss = def_xmm_ss "divss" $ fpDiv SingleFloatRepr

-- | ADDPS Add packed single-precision floating-point values
def_addps :: InstructionDef
def_addps = defBinaryXMMV "addps" $ \l v -> do
  fmap_loc l $ \lv -> vectorize2 n32 (fpAdd SingleFloatRepr) lv v

-- SUBPS Subtract packed single-precision floating-point values
def_subps :: InstructionDef
def_subps = defBinaryXMMV "subps" $ \l v -> do
  fmap_loc l $ \lv -> vectorize2 n32 (fpSub SingleFloatRepr) lv v

-- | MULPS Multiply packed single-precision floating-point values
def_mulps :: InstructionDef
def_mulps = defBinaryXMMV "mulps" $ \l v -> do
  fmap_loc l $ \lv -> vectorize2 n64 (fpMul DoubleFloatRepr) lv v

-- DIVPS Divide packed single-precision floating-point values


-- RCPPS Compute reciprocals of packed single-precision floating-point values
-- RCPSS Compute reciprocal of scalar single-precision floating-point values
-- SQRTPS Compute square roots of packed single-precision floating-point values
-- SQRTSS Compute square root of scalar single-precision floating-point values
-- RSQRTPS Compute reciprocals of square roots of packed single-precision floating-point values
-- RSQRTSS Compute reciprocal of square root of scalar single-precision floating-point values
-- MAXPS Return maximum packed single-precision floating-point values
-- MAXSS Return maximum scalar single-precision floating-point values
-- MINPS Return minimum packed single-precision floating-point values
-- MINSS Return minimum scalar single-precision floating-point values

-- *** SSE Comparison Instructions

-- CMPPS Compare packed single-precision floating-point values
-- CMPSS Compare scalar single-precision floating-point values
-- COMISS Perform ordered comparison of scalar single-precision floating-point values and set flags in EFLAGS register
-- | UCOMISS Perform unordered comparison of scalar single-precision floating-point values and set flags in EFLAGS register
def_ucomiss :: InstructionDef
-- Invalid (if SNaN operands), Denormal.
def_ucomiss = defBinaryXMMV "ucomiss" $ \l v -> do
  v' <- bvTrunc knownNat <$> get l
  let fir = SingleFloatRepr
  let unordered = (isNaN fir v .||. isNaN fir v')
      lt        = fpLt fir v' v
      eq        = fpEq fir v' v

  zf_loc .= (unordered .||. eq)
  pf_loc .= unordered
  cf_loc .= (unordered .||. lt)

  of_loc .= false
  af_loc .= false
  sf_loc .= false

-- *** SSE Logical Instructions

exec_andpx :: (Semantics m, 1 <= elsz) => NatRepr elsz -> MLocation m XMMType -> Value m XMMType -> m ()
exec_andpx elsz l v = fmap_loc l $ \lv -> vectorize2 elsz (.&.) lv v

-- | ANDPS Perform bitwise logical AND of packed single-precision floating-point values
def_andps :: InstructionDef
def_andps = defBinaryKnown "andps" $ exec_andpx n32

-- ANDNPS Perform bitwise logical AND NOT of packed single-precision floating-point values

exec_orpx :: (Semantics m, 1 <= elsz) => NatRepr elsz -> MLocation m XMMType -> Value m XMMType -> m ()
exec_orpx elsz l v = fmap_loc l $ \lv -> vectorize2 elsz (.|.) lv v

-- | ORPS Perform bitwise logical OR of packed single-precision floating-point values
def_orps :: InstructionDef
def_orps = defBinaryKnown "orps" $ exec_orpx n32

-- XORPS Perform bitwise logical XOR of packed single-precision floating-point values

def_xorps :: InstructionDef
def_xorps =
  defBinary "xorps" $ \_ loc val -> do
    l <- getBVLocation loc n128
    v <- readXMMValue val
    modify l (`bvXor` v)

-- *** SSE Shuffle and Unpack Instructions

-- SHUFPS Shuffles values in packed single-precision floating-point operands
-- UNPCKHPS Unpacks and interleaves the two high-order values from two single-precision floating-point operands
-- | UNPCKLPS Unpacks and interleaves the two low-order values from two single-precision floating-point operands

interleave :: [a] -> [a] -> [a]
interleave xs ys = concat (zipWith (\x y -> [x, y]) xs ys)

def_unpcklps :: InstructionDef
def_unpcklps = defBinaryKnown "unpcklps" exec
  where exec :: Semantics m => MLocation m XMMType -> Value m XMMType -> m ()
        exec l v = fmap_loc l $ \lv -> do
          let lsd = drop 2 $ bvVectorize n32 lv
              lss = drop 2 $ bvVectorize n32 v
          bvUnvectorize (typeWidth l) (interleave lss lsd)

-- *** SSE Conversion Instructions

-- CVTPI2PS Convert packed doubleword integers to packed single-precision floating-point values
-- CVTSI2SS Convert doubleword integer to scalar single-precision floating-point value
def_cvtsi2ss :: InstructionDef
def_cvtsi2ss =
  defBinary "cvtsi2ss" $ \_ loc val -> do
    -- Loc is RG_XMM_reg
    -- val is "OpType ModRM_rm YSize"
    d <- getXMM loc
    ev <- getRM32_RM64 val
    -- Read second argument value and coerce to single precision float.
    r <-
      case ev of
        Left v  -> fpFromBV SingleFloatRepr <$> get v
        Right v -> fpFromBV SingleFloatRepr <$> get v
    -- Assign low 32-bits.
    xmm_low32 d .= r

-- | CVTSI2SD  Convert doubleword integer to scalar double-precision floating-point value
def_cvtsi2sd :: InstructionDef
def_cvtsi2sd =
  defBinary "cvtsi2sd" $ \_ loc val -> do
    d <- getXMM loc
    ev <- getRM32_RM64 val
    v <-
      case ev of
        Left v  -> fpFromBV DoubleFloatRepr <$> get v
        Right v -> fpFromBV DoubleFloatRepr <$> get v
    xmm_low64 d .= v

-- CVTPS2PI Convert packed single-precision floating-point values to packed doubleword integers
-- CVTTPS2PI Convert with truncation packed single-precision floating-point values to packed doubleword integers
-- CVTSS2SI Convert a scalar single-precision floating-point value to a doubleword integer

-- | CVTTSS2SI Convert with truncation a scalar single-precision floating-point value to a scalar doubleword integer
def_cvttss2si :: InstructionDef
-- Invalid, Precision.  Returns 80000000 if exception is masked
def_cvttss2si =
  defBinary "cvttss2si" $ \_ loc val -> do
    SomeBV l  <- getSomeBVLocation loc
    v <- truncateBVValue knownNat =<< getSomeBVValue val
    l .= truncFPToSignedBV (typeWidth l) SingleFloatRepr v

-- ** SSE MXCSR State Management Instructions

-- LDMXCSR Load MXCSR register
-- STMXCSR Save MXCSR register state

-- ** SSE 64-Bit SIMD Integer Instructions

-- replace pairs with the left operand if `op` is true (e.g., bvUlt for min)
pselect :: (IsLocationBV m n, 1 <= o)
        => (Value m (BVType o) -> Value m (BVType o) -> Value m BoolType)
        -> NatRepr o
        -> MLocation m (BVType n) -> Value m (BVType n) -> m ()
pselect op sz l v = do
  v0 <- get l
  l .= vectorize2 sz chkPair v0 v
  where chkPair d s = mux (d `op` s) d s

-- PAVGB Compute average of packed unsigned byte integers
-- PAVGW Compute average of packed unsigned word integers
-- PEXTRW Extract word

-- | PINSRW Insert word
exec_pinsrw :: Semantics m => MLocation m XMMType -> Value m (BVType 16) -> Int8 -> m ()
exec_pinsrw l v off = do
  lv <- get l
  -- FIXME: is this the right way around?
  let ls = bvVectorize n16 lv
      (lower, _ : upper) = splitAt (fromIntegral off - 1) ls
      ls' = lower ++ [v] ++ upper
  l .= bvUnvectorize knownNat ls'

def_pinsrw :: InstructionDef
def_pinsrw = defTernary "pinsrw" $ \_ loc val imm -> do
  l  <- getBVLocation loc knownNat
  v  <- truncateBVValue knownNat =<< getSomeBVValue val
  case imm of
    F.ByteImm off -> exec_pinsrw l v off
    _ -> fail "Bad offset to pinsrw"

-- PMAXUB Maximum of packed unsigned byte integers
-- PMAXSW Maximum of packed signed word integers
-- PMINUB Minimum of packed unsigned byte integers
-- PMINSW Minimum of packed signed word integers
def_pmaxu :: (1 <= w) => String -> NatRepr w -> InstructionDef
def_pmaxu mnem w = defBinaryLV mnem $ pselect (flip bvUlt) w

def_pmaxs :: (1 <= w) => String -> NatRepr w -> InstructionDef
def_pmaxs mnem w = defBinaryLV mnem $ pselect (flip bvSlt) w

def_pminu :: (1 <= w) => String -> NatRepr w -> InstructionDef
def_pminu mnem w = defBinaryLV mnem $ pselect bvUlt w

def_pmins :: (1 <= w) => String -> NatRepr w -> InstructionDef
def_pmins mnem w = defBinaryLV mnem $ pselect bvSlt w

exec_pmovmskb :: forall m n n'. (IsLocationBV m n)
              => MLocation m (BVType n)
              -> Value m (BVType n')
              -> m ()
exec_pmovmskb l v
  | Just Refl <- testEquality (bv_width v) n64 = do
      l .= uext (typeWidth l) (mkMask n8 v)
  | Just LeqProof <- testLeq n32 (typeWidth l)
  , Just Refl <- testEquality (bv_width v) n128 = do
      let prf = withLeqProof (leqTrans (LeqProof :: LeqProof 16 32)
                                       (LeqProof :: LeqProof 32 n))
      l .= prf (uext (typeWidth l) (mkMask n16 v))
  | otherwise = fail "pmovmskb: Unknown bit width"
  where mkMask sz src = bvUnvectorize sz $ map f $ bvVectorize n8 src
        f b = mux (msb b) (bvLit n1 1) (bvLit n1 0)

-- PMULHUW Multiply packed unsigned integers and store high result
-- PSADBW Compute sum of absolute differences
-- PSHUFW Shuffle packed integer word in MMX register

-- ** SSE Cacheability Control, Prefetch, and Instruction Ordering Instructions

-- MASKMOVQ Non-temporal store of selected bytes from an MMX register into memory
-- MOVNTQ  Non-temporal store of quadword from an MMX register into memory
-- MOVNTPS Non-temporal store of four packed single-precision floating-point
--   values from an XMM register into memory
-- PREFETCHh Load 32 or more of bytes from memory to a selected level of the
--   processor's cache hierarchy
-- SFENCE Serializes store operations

-- * SSE2 Instructions
-- ** SSE2 Packed and Scalar Double-Precision Floating-Point Instructions
-- *** SSE2 Data Movement Instructions

-- | MOVAPD Move two aligned packed double-precision floating-point values
-- between XMM registers or between and XMM register and memory
def_movapd :: InstructionDef
def_movapd = defBinaryXMMV "movapd" $ \l v -> l .= v

-- | MOVUPD Move two unaligned packed double-precision floating-point values
--   between XMM registers or between and XMM register and memory
def_movupd :: InstructionDef
def_movupd = defBinaryXMMV "movupd" $ \l v -> l .= v

exec_movhpd, exec_movlpd :: forall m n n'. (IsLocationBV m n, 1 <= n')
                         => MLocation m (BVType n)
                         -> Value m (BVType n')
                         -> m ()
exec_movhpd l v = do
  v0 <- get l
  let dstPieces = bvVectorize n64 v0
      srcPieces = bvVectorize n64 v
      rPieces = [head srcPieces] ++ (drop 1 dstPieces)
  l .= bvUnvectorize (typeWidth l) rPieces
exec_movlpd l v = do
  v0 <- get l
  let dstPieces = bvVectorize n64 v0
      srcPieces = bvVectorize n64 v
      rPieces =  (init dstPieces) ++ [last srcPieces]
  l .= bvUnvectorize (typeWidth l) rPieces

-- MOVMSKPD Extract sign mask from two packed double-precision floating-point values

-- *** SSE2 Packed Arithmetic Instructions

-- | This evaluates an instruction that takes xmm and xmm/m64 arguments,
-- and applies a function that updates the low 64-bits of the first argument.
def_xmm_sd :: String
              -- ^ Instruction mnemonic
           -> (forall v . IsValue v
               => v (FloatType DoubleFloat)
               -> v (FloatType DoubleFloat)
               -> v (FloatType DoubleFloat))
              -- ^ Binary operation
           -> InstructionDef
def_xmm_sd mnem f =
  defBinary mnem $ \_ loc val -> do
    d <- getXMM loc
    y <- get =<< getXMM_mr_low64 val
    modify (xmm_low64 d) $ \x -> f x y

-- | ADDSD Add scalar double precision floating-point values
def_addsd :: InstructionDef
def_addsd = def_xmm_sd "addsd" $ fpAdd DoubleFloatRepr

-- | SUBSD Subtract scalar double-precision floating-point values
def_subsd :: InstructionDef
def_subsd = def_xmm_sd "subsd" $ fpSub DoubleFloatRepr

-- | MULSD Multiply scalar double-precision floating-point values
def_mulsd :: InstructionDef
def_mulsd = def_xmm_sd "mulsd" $ fpMul DoubleFloatRepr

-- | DIVSD Divide scalar double-precision floating-point values
def_divsd :: InstructionDef
def_divsd = def_xmm_sd "divsd" $ fpDiv DoubleFloatRepr

-- ADDPD Add packed double-precision floating-point values
-- SUBPD Subtract scalar double-precision floating-point values
-- MULPD Multiply packed double-precision floating-point values

-- DIVPD Divide packed double-precision floating-point values

-- SQRTPD Compute packed square roots of packed double-precision floating-point values
-- SQRTSD Compute scalar square root of scalar double-precision floating-point values
-- MAXPD Return maximum packed double-precision floating-point values
-- MAXSD Return maximum scalar double-precision floating-point values
-- MINPD Return minimum packed double-precision floating-point values
-- MINSD Return minimum scalar double-precision floating-point values

-- *** SSE2 Logical Instructions

-- | ANDPD  Perform bitwise logical AND of packed double-precision floating-point values
def_andpd :: InstructionDef
def_andpd = defBinaryKnown "andpd" $ exec_andpx n64

-- ANDNPD Perform bitwise logical AND NOT of packed double-precision floating-point values
-- | ORPD   Perform bitwise logical OR of packed double-precision floating-point values
def_orpd :: InstructionDef
def_orpd = defBinaryKnown "orpd" $ exec_orpx n64

-- XORPD  Perform bitwise logical XOR of packed double-precision floating-point values

def_xorpd :: InstructionDef
def_xorpd =
  defBinary "xorpd" $ \_ loc val -> do
    l <- getBVLocation loc n128
    v <- readXMMValue val
    modify l (`bvXor` v)

-- *** SSE2 Compare Instructions

-- CMPPD Compare packed double-precision floating-point values
-- | CMPSD Compare scalar double-precision floating-point values
def_cmpsd :: InstructionDef
def_cmpsd =
  defTernary "cmpsd" $ \_ loc f_val imm -> do
    l  <- getXMM loc
    v  <- get =<< getXMM_mr_low64 f_val
    f <- case imm of
           F.ByteImm opcode ->
             case opcode of
               0 -> return $ fpEq DoubleFloatRepr
               1 -> return $ fpLt DoubleFloatRepr
               2 -> fail "cmpsd: CMPLESD case unimplemented" -- FIXME
               3 -> fail "cmpsd: CMPUNORDSD case unimplemented" -- FIXME
               4 -> fail "cmpsd: CMPNEWSD case unimplemented" -- FIXME
               5 -> return $ \x y -> boolNot (fpLt DoubleFloatRepr x y)
               6 -> fail "cmpsd: CMPNLESD case unimplemented" -- FIXME
               7 -> fail "cmpsd: CMPORDSD case unimplemented" -- FIXME
               _ -> fail ("cmpsd: unexpected opcode " ++ show opcode)
           _ -> fail "Impossible argument in cmpsd"
    modify (xmm_low64 l) $ \lv -> do
      let res = f lv v
          allOnes  = bvLit knownNat (-1)
          allZeros = bvLit knownNat 0
      mux res allOnes allZeros

-- COMISD Perform ordered comparison of scalar double-precision floating-point values and set flags in EFLAGS register

-- | UCOMISD Perform unordered comparison of scalar double-precision
-- floating-point values and set flags in EFLAGS register.
def_ucomisd :: InstructionDef
-- Invalid (if SNaN operands), Denormal.
def_ucomisd = defBinaryXMMV "ucomisd" $ \l v -> do
  let fir = DoubleFloatRepr
  v' <- bvTrunc knownNat <$> get l
  let unordered = (isNaN fir v .||. isNaN fir v')
      lt        = fpLt fir v' v
      eq        = fpEq fir v' v

  zf_loc .= (unordered .||. eq)
  pf_loc .= unordered
  cf_loc .= (unordered .||. lt)

  of_loc .= false
  af_loc .= false
  sf_loc .= false

-- *** SSE2 Shuffle and Unpack Instructions

-- CMPPD Compare packed double-precision floating-point values
-- CMPSD Compare scalar double-precision floating-point values
-- COMISD Perform ordered comparison of scalar double-precision floating-point values and set flags in EFLAGS register
-- UCOMISD Perform unordered comparison of scalar double-precision floating-point values and set flags in EFLAGS register.

-- *** SSE2 Conversion Instructions

-- CVTPD2PI  Convert packed double-precision floating-point values to packed doubleword integers.
-- CVTTPD2PI Convert with truncation packed double-precision floating-point values to packed doubleword integers
-- CVTPI2PD  Convert packed doubleword integers to packed double-precision floating-point values
-- CVTPD2DQ  Convert packed double-precision floating-point values to packed doubleword integers
-- CVTTPD2DQ Convert with truncation packed double-precision floating-point values to packed doubleword integers
-- CVTDQ2PD  Convert packed doubleword integers to packed double-precision floating-point values
-- CVTPS2PD  Convert packed single-precision floating-point values to packed double-precision floating- point values
-- CVTPD2PS  Convert packed double-precision floating-point values to packed single-precision floating- point values

-- | CVTSS2SD  Convert scalar single-precision floating-point values to
-- scalar double-precision floating-point values
def_cvtss2sd :: InstructionDef
def_cvtss2sd = defBinary "cvtss2sd" $ \_ loc val -> do
  r <- getXMM loc
  v <- get =<< getXMM_mr_low32 val
  xmm_low64 r .= fpCvt SingleFloatRepr DoubleFloatRepr v

-- | CVTSD2SS Convert scalar double-precision floating-point values to
-- scalar single-precision floating-point values
def_cvtsd2ss :: InstructionDef
def_cvtsd2ss = defBinary "cvtss2ss" $ \_ loc val -> do
  r <- getXMM loc
  v <- get =<< getXMM_mr_low64 val
  xmm_low32 r .= fpCvt DoubleFloatRepr SingleFloatRepr  v

-- CVTSD2SI  Convert scalar double-precision floating-point values to a doubleword integer

-- | CVTTSD2SI Convert with truncation scalar double-precision floating-point values to scalar doubleword integers
def_cvttsd2si :: InstructionDef
-- Invalid, Precision.  Returns 80000000 if exception is masked
def_cvttsd2si =
  defBinary "cvttsd2si" $ \_ loc val -> do
    l  <- getReg32_Reg64 loc
    v <- get =<< getXMM_mr_low64 val
    case l of
      Left  r -> r .= truncFPToSignedBV n32 DoubleFloatRepr v
      Right r -> r .= truncFPToSignedBV n64 DoubleFloatRepr v

-- ** SSE2 Packed Single-Precision Floating-Point Instructions

-- CVTDQ2PS  Convert packed doubleword integers to packed single-precision floating-point values
-- CVTPS2DQ  Convert packed single-precision floating-point values to packed doubleword integers
-- CVTTPS2DQ Convert with truncation packed single-precision floating-point values to packed doubleword integers

-- ** SSE2 128-Bit SIMD Integer Instructions

-- | MOVDQA Move aligned double quadword.

-- FIXME: exception on unaligned loads
def_movdqa :: InstructionDef
def_movdqa = defBinaryXMMV "movdqa" $ \l v -> l .= v

-- | MOVDQU Move unaligned double quadword

-- FIXME: no exception on unaligned loads
def_movdqu :: InstructionDef
def_movdqu = defBinaryXMMV "movdqu" $ \l v -> l .= v

-- MOVQ2DQ Move quadword integer from MMX to XMM registers
-- MOVDQ2Q Move quadword integer from XMM to MMX registers
-- PMULUDQ Multiply packed unsigned doubleword integers
-- | PADDQ Add packed quadword integers
-- FIXME: this can also take 64 bit values?
exec_paddq :: Binop
exec_paddq l v = do
  v0 <- get l
  l .= vectorize2 n64 bvAdd v0 v

-- PSUBQ Subtract packed quadword integers
-- PSHUFLW Shuffle packed low words
-- PSHUFHW Shuffle packed high words

exec_pshufd :: forall m n k. (IsLocationBV m n, 1 <= k)
            => MLocation m (BVType n)
            -> Value m (BVType n)
            -> Value m (BVType k)
            -> m ()
exec_pshufd l v imm
  | Just Refl <- testEquality (bv_width imm) n8 = do
      let order = bvVectorize (addNat n1 n1) imm
          dstPieces = concatMap (\src128 -> map (getPiece src128) order) $ bvVectorize n128 v
      l .= bvUnvectorize (typeWidth l) dstPieces
  | otherwise = fail "pshufd: Unknown bit width"
  where shiftAmt :: Value m (BVType 2) -> Value m (BVType 128)
        shiftAmt pieceID = bvMul (uext n128 pieceID) $ bvLit n128 32

        getPiece :: Value m (BVType 128) -> Value m (BVType 2) -> Value m (BVType 32)
        getPiece src pieceID = bvTrunc n32 $ src `bvShr` (shiftAmt pieceID)

exec_pslldq :: (IsLocationBV m n, 1 <= n', n' <= n)
            => MLocation m (BVType n) -> Value m (BVType n') -> m ()
exec_pslldq l v = do
  v0 <- get l
  -- temp is 16 if v is greater than 15, otherwise v
  let not15 = bvComplement $ bvLit (bv_width v) 15
      temp = mux (is_zero $ not15 .&. v)
                 (uext (bv_width v0) v)
                 (bvLit (bv_width v0) 16)
  l .= v0 `bvShl` (temp .* bvLit (bv_width v0) 8)

-- PSRLDQ Shift double quadword right logical
-- PUNPCKHQDQ Unpack high quadwords
-- PUNPCKLQDQ Unpack low quadwords

-- ** SSE2 Cacheability Control and Ordering Instructions


-- CLFLUSH Flushes and invalidates a memory operand and its associated cache line from all levels of the processor’s cache hierarchy
-- LFENCE Serializes load operations
-- MFENCE Serializes load and store operations
-- PAUSE      Improves the performance of “spin-wait loops”
-- MASKMOVDQU Non-temporal store of selected bytes from an XMM register into memory
-- MOVNTPD    Non-temporal store of two packed double-precision floating-point values from an XMM register into memory
-- MOVNTDQ    Non-temporal store of double quadword from an XMM register into memory
-- MOVNTI     Non-temporal store of a doubleword from a general-purpose register into memory

-- * SSE3 Instructions
-- ** SSE3 x87-FP Integer Conversion Instruction

-- FISTTP Behaves like the FISTP instruction but uses truncation, irrespective of the rounding mode specified in the floating-point control word (FCW)

-- ** SSE3 Specialized 128-bit Unaligned Data Load Instruction

def_lddqu :: InstructionDef
def_lddqu = defBinary "lddqu"  $ \_ loc val -> do
  l <- getBVLocation loc n128
  v <- case val of
    F.VoidMem a -> readBVAddress a xmmMemRepr
    _ -> fail "readVoidMem given bad address."
  l .= v

-- ** SSE3 SIMD Floating-Point Packed ADD/SUB Instructions

-- ADDSUBPS Performs single-precision addition on the second and fourth pairs of 32-bit data elements within the operands; single-precision subtraction on the first and third pairs
-- ADDSUBPD Performs double-precision addition on the second pair of quadwords, and double-precision subtraction on the first pair

-- ** SSE3 SIMD Floating-Point Horizontal ADD/SUB Instructions

-- HADDPS Performs a single-precision addition on contiguous data elements. The first data element of the result is obtained by adding the first and second elements of the first operand; the second element by adding the third and fourth elements of the first operand; the third by adding the first and second elements of the second operand; and the fourth by adding the third and fourth elements of the second operand.
-- HSUBPS Performs a single-precision subtraction on contiguous data elements. The first data element of the result is obtained by subtracting the second element of the first operand from the first element of the first operand; the second element by subtracting the fourth element of the first operand from the third element of the first operand; the third by subtracting the second element of the second operand from the first element of the second operand; and the fourth by subtracting the fourth element of the second operand from the third element of the second operand.
-- HADDPD Performs a double-precision addition on contiguous data elements. The first data element of the result is obtained by adding the first and second elements of the first operand; the second element by adding the first and second elements of the second operand.
-- HSUBPD Performs a double-precision subtraction on contiguous data elements. The first data element of the result is obtained by subtracting the second element of the first operand from the first element of the first operand; the second element by subtracting the second element of the second operand from the first element of the second operand.


-- ** SSE3 SIMD Floating-Point LOAD/MOVE/DUPLICATE Instructions

-- MOVSHDUP Loads/moves 128 bits; duplicating the second and fourth 32-bit data elements
-- MOVSLDUP Loads/moves 128 bits; duplicating the first and third 32-bit data elements
-- MOVDDUP Loads/moves 64 bits (bits[63:0] if the source is a register) and returns the same 64 bits in both the lower and upper halves of the 128-bit result register; duplicates the 64 bits from the source

-- ** SSE3 Agent Synchronization Instructions

-- MONITOR Sets up an address range used to monitor write-back stores
-- MWAIT Enables a logical processor to enter into an optimized state while waiting for a write-back store to the address range set up by the MONITOR instruction


-- * Supplemental Streaming SIMD Extensions 3 (SSSE3) Instructions
-- ** Horizontal Addition/Subtraction

-- PHADDW Adds two adjacent, signed 16-bit integers horizontally from the source and destination operands and packs the signed 16-bit results to the destination operand.
-- PHADDSW Adds two adjacent, signed 16-bit integers horizontally from the source and destination operands and packs the signed, saturated 16-bit results to the destination operand.
-- PHADDD Adds two adjacent, signed 32-bit integers horizontally from the source and destination operands and packs the signed 32-bit results to the destination operand.
-- PHSUBW Performs horizontal subtraction on each adjacent pair of 16-bit signed integers by subtracting the most significant word from the least significant word of each pair in the source and destination operands. The signed 16-bit results are packed and written to the destination operand.
-- PHSUBSW Performs horizontal subtraction on each adjacent pair of 16-bit signed integers by subtracting the most significant word from the least significant word of each pair in the source and destination operands. The signed, saturated 16-bit results are packed and written to the destination operand.
-- PHSUBD Performs horizontal subtraction on each adjacent pair of 32-bit signed integers by subtracting the most significant doubleword from the least significant double word of each pair in the source and destination operands. The signed 32-bit results are packed and written to the destination operand.

-- ** Packed Absolute Values

-- PABSB Computes the absolute value of each signed byte data element.
-- PABSW Computes the absolute value of each signed 16-bit data element.
-- PABSD Computes the absolute value of each signed 32-bit data element.

-- ** Multiply and Add Packed Signed and Unsigned Bytes

-- PMADDUBSW Multiplies each unsigned byte value with the corresponding signed byte value to produce an intermediate, 16-bit signed integer. Each adjacent pair of 16-bit signed values are added horizontally. The signed, saturated 16-bit results are packed to the destination operand.

-- ** Packed Multiply High with Round and Scale

-- PMULHRSW Multiplies vertically each signed 16-bit integer from the destination operand with the corresponding signed 16-bit integer of the source operand, producing intermediate, signed 32-bit integers. Each intermediate 32-bit integer is truncated to the 18 most significant bits. Rounding is always performed by adding 1 to the least significant bit of the 18-bit intermediate result. The final result is obtained by selecting the 16 bits immediately to the right of the most significant bit of each 18-bit intermediate result and packed to the destination operand.

-- ** Packed Shuffle Bytes

-- PSHUFB Permutes each byte in place, according to a shuffle control mask. The least significant three or four bits of each shuffle control byte of the control mask form the shuffle index. The shuffle mask is unaffected. If the most significant bit (bit 7) of a shuffle control byte is set, the constant zero is written in the result byte.


-- ** Packed Sign

-- PSIGNB/W/D Negates each signed integer element of the destination operand if the sign of the corresponding data element in the source operand is less than zero.

-- ** Packed Align Right

exec_palignr :: forall m n k. (IsLocationBV m n, 1 <= k, k <= n)
             => MLocation m (BVType n)
             -> Value m (BVType n)
             -> Value m (BVType k)
             -> m ()
exec_palignr l v imm = do
  v0 <- get l

  -- 1 <= n+n, given 1 <= n
  withLeqProof (dblPosIsPos (LeqProof :: LeqProof 1 n)) $ do
  -- k <= (n+n), given k <= n and n <= n+n
  withLeqProof (leqTrans k_leq_n (leqAdd (leqRefl n) n)) $ do

  -- imm is # of bytes to shift, so multiply by 8 for bits to shift
  let n_plus_n = addNat (bv_width v) (bv_width v)
      shiftAmt = bvMul (uext n_plus_n imm) $ bvLit n_plus_n 8

  let (_, lower) = bvSplit $ (v0 `bvCat` v) `bvShr` shiftAmt
  l .= lower

  where n :: Proxy n
        n = Proxy
        k_leq_n :: LeqProof k n
        k_leq_n = LeqProof

------------------------------------------------------------------------
-- Instruction list


all_instructions :: [InstructionDef]
all_instructions =
  [ def_lea
  , def_call
  , def_jmp
  , def_ret
  , def_cwd
  , def_cdq
  , def_cqo
  , def_movsx
  , def_movsxd
  , def_movzx
  , def_xchg
  , def_cmps
  , def_movs
  , def_lods
  , def_lodsx "lodsb" n8
  , def_lodsx "lodsw" n16
  , def_lodsx "lodsd" n32
  , def_lodsx "lodsq" n64
  , def_stos
  , def_scas

    -- fixed size instructions.  We truncate in the case of
    -- an xmm register, for example
  , def_addsd
  , def_subsd
  , def_movsd
  , def_movapd
  , def_movaps
  , def_movups
  , def_movupd
  , def_movdqa
  , def_movdqu
  , def_movss
  , def_mulsd
  , def_divsd
  , def_psllx "psllw" n16
  , def_psllx "pslld" n32
  , def_psllx "psllq" n64
  , def_ucomisd
  , def_xorpd
  , def_xorps

  , def_cvtsi2ss
  , def_cvtsd2ss
  , def_cvtsi2sd
  , def_cvtss2sd
  , def_cvttsd2si
  , def_cvttss2si
  , def_pinsrw
  , def_cmpsd
  , def_andpd
  , def_orpd
  , def_unpcklps

    -- regular instructions
  , defBinaryLV "add" exec_add
  , defBinaryLV "adc" exec_adc
  , defBinaryLV "and" exec_and
  , defBinaryLVge "bt"  exec_bt
  , defBinaryLVge "btc" exec_btc
  , defBinaryLVge "btr" exec_btr
  , defBinaryLVge "bts" exec_bts
  , defBinaryLV "bsf" exec_bsf
  , defBinaryLV "bsr" exec_bsr
  , defUnaryLoc "bswap" $ exec_bswap
  , def_cbw
  , def_cwde
  , def_cdqe
  , defNullary  "clc"  $ cf_loc .= false
  , defNullary  "cld"  $ df_loc .= false
  , defBinaryLV "cmp"   exec_cmp
  , defUnaryLoc  "dec" $ exec_dec
  , def_div
  , def_hlt
  , def_idiv
  , def_imul

  , defUnaryLoc "inc"   $ exec_inc
  , defNullary  "leave" $ exec_leave
  , defBinaryLV "mov"   $ exec_mov
  , defUnaryV   "mul"   $ exec_mul
  , def_neg
  , defNullary  "nop"   $ return ()
  , defUnaryLoc "not"   $ \l -> modify l bvComplement
  , defBinaryLV "or"    $ exec_or
  , defNullary "pause"  $ return ()
  , def_pop

  , def_cmpxchg
  , defUnaryKnown "cmpxchg8b" exec_cmpxchg8b
  , def_push
  , defBinaryLVge "rol"  exec_rol
  , defBinaryLVge "ror"  exec_ror
  , def_sahf
  , defBinaryLV   "sbb"  exec_sbb
  , defBinaryLVge "sar"  exec_sar
  , defBinaryLVge "shl"  exec_shl
  , defBinaryLVge "shr"  exec_shr
  , defNullary    "std" $ df_loc .= true
  , defBinaryLV   "sub" exec_sub
  , defBinaryLV   "test" exec_test
  , def_xadd
  , defBinaryLV "xor" exec_xor

  , defNullary "ud2"     $ exception false true UndefinedInstructionError

    -- Primitive instructions
  , defNullary "syscall" $ primitive Syscall
  , defNullary "cpuid"   $ primitive CPUID
  , defNullary "rdtsc"   $ primitive RDTSC
  , defNullary "xgetbv"  $ primitive XGetBV

    -- MMX instructions
  , defBinaryLVpoly "movd" exec_movd
  , defBinaryLVpoly "movq" exec_movq
  , defBinaryLV "punpckhbw"  $ exec_punpckhbw
  , defBinaryLV "punpckhwd"  $ exec_punpckhwd
  , defBinaryLV "punpckhdq"  $ exec_punpckhdq
  , defBinaryLV "punpckhqdq" $ exec_punpckhqdq
  , defBinaryLV "punpcklbw"  $ exec_punpcklbw
  , defBinaryLV "punpcklwd"  $ exec_punpcklwd
  , defBinaryLV "punpckldq"  $ exec_punpckldq
  , defBinaryLV "punpcklqdq" $ exec_punpcklqdq
  , defBinaryLV "paddb"      $ exec_paddb
  , defBinaryLV "paddw"      $ exec_paddw
  , defBinaryLV "paddq"      $ exec_paddq
  , defBinaryLV "paddd"      $ exec_paddd
  , defBinaryLV "psubb"      $ exec_psubb
  , defBinaryLV "psubw"      $ exec_psubw
  , defBinaryLV "psubd"      $ exec_psubd
  , defBinaryLV "pcmpeqb"    $ exec_pcmpeqb
  , defBinaryLV "pcmpeqw"    $ exec_pcmpeqw
  , defBinaryLV "pcmpeqd"    $ exec_pcmpeqd
  , defBinaryLV "pcmpgtb"    $ exec_pcmpgtb
  , defBinaryLV "pcmpgtw"    $ exec_pcmpgtw
  , defBinaryLV "pcmpgtd"    $ exec_pcmpgtd
  , defBinaryLV "pand"       $ exec_pand
  , defBinaryLV "pandn"      $ exec_pandn
  , defBinaryLV "por"        $ exec_por
  , defBinaryLV "pxor"       $ exec_pxor

    -- SSE instructions
  , def_movhlps
  , def_movhps
  , def_movlhps
  , def_movlps
    -- SSE Packed
  , def_addps
  , def_addss
  , def_subps
  , def_subss
  , def_mulps
  , def_mulss
  , def_divss
    -- SSE Comparison
  , def_ucomiss
    -- SSE Logical
  , def_andps
  , def_orps

  , def_pmaxu "pmaxub"  n8
  , def_pmaxu "pmaxuw" n16
  , def_pmaxu "pmaxud" n32

  , def_pmaxs "pmaxsb"  n8
  , def_pmaxs "pmaxsw" n16
  , def_pmaxs "pmaxsd" n32

  , def_pminu "pminub"  n8
  , def_pminu "pminuw" n16
  , def_pminu "pminud" n32

  , def_pmins "pminsb"  n8
  , def_pmins "pminsw" n16
  , def_pmins "pminsd" n32

  , defBinaryLVpoly "pmovmskb" exec_pmovmskb
  , defBinaryLVpoly "movhpd"   exec_movhpd
  , defBinaryLVpoly "movlpd"   exec_movlpd
  , def_pshufb

  , defTernaryLVV  "pshufd" exec_pshufd
  , defBinaryLVge "pslldq" exec_pslldq
  , def_lddqu
  , defTernaryLVV "palignr" exec_palignr
    -- X87 FP instructions
  , defFPBinaryImplicit "fadd"   $ exec_fadd
  , defUnaryFPV      "fld"   $ exec_fld
  , defFPBinaryImplicit "fmul"   $ exec_fmul
  , def_fnstcw -- stores to bv memory (i.e., not FP)
  , defUnaryFPL     "fst"   $ exec_fst
  , def_fstp
  , defFPBinaryImplicit "fsub"   $ exec_fsub
  , defFPBinaryImplicit "fsubp"  $ exec_fsubp
  , defFPBinaryImplicit "fsubr"  $ exec_fsubr
  , defFPBinaryImplicit "fsubrp" $ exec_fsubrp
  ]
  ++ def_cmov_list
  ++ def_jcc_list
  ++ def_set_list

------------------------------------------------------------------------
-- execInstruction

mapNoDupFromList :: (Ord k, Show k) => [(k,v)] -> Either k (Map k v)
mapNoDupFromList = foldlM ins M.empty
  where ins m (k,v) =
          case M.lookup k m of
            Just _ -> Left k
            Nothing -> Right (M.insert k v m)

-- | A map from instruction mnemonics to their semantic definitions
semanticsMap :: Map String InstructionSemantics
semanticsMap =
  case mapNoDupFromList all_instructions of
    Right m -> m
    Left k -> error $ "semanticsMap contains duplicate entries for " ++ show k ++ "."

-- | Execute an instruction if definined in the map or return nothing.
execInstruction :: Semantics m
                => Value m (BVType 64)
                   -- ^ Next ip address
                -> F.InstructionInstance
                -> Maybe (m ())
execInstruction next ii =
  case M.lookup (F.iiOp ii) semanticsMap of
    Just (InstructionSemantics f) -> Just $ do
      rip .= next
      f ii
    Nothing -> Nothing
