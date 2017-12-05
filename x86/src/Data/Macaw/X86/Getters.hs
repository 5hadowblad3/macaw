{-|
Copyright        : (c) Galois, Inc 2015-2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>

This defines operations for mapping flexdis values to Macaw values.
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
module Data.Macaw.X86.Getters
  ( SomeBV(..)
  , getBVAddress
  , readBVAddress
  , getSomeBVLocation
  , getBVLocation
  , getSomeBVValue
  , getBVValue
  , getSignExtendedValue
  , truncateBVValue
  , getJumpTarget
  , FPLocation(..)
  , getFPLocation
  , FPValue(..)
  , getFPValue
  , HasRepSize(..)
  , getAddrRegOrSegment
  , getAddrRegSegmentOrImm
  , readXMMValue
  , readXMMOrMem32
  , readXMMOrMem64
    -- * Utilities
  , reg16Loc
  , reg32Loc
  , reg64Loc
  , getBV8Addr
  , getBV16Addr
  , getBV32Addr
  , getBV64Addr
  , getBV128Addr
    -- * Reprs
  , byteMemRepr
  , wordMemRepr
  , dwordMemRepr
  , qwordMemRepr
  , xmmMemRepr
  ) where

import           Data.Parameterized.NatRepr
import           Data.Parameterized.Some
import qualified Flexdis86 as F
import           GHC.TypeLits (KnownNat)

import           Data.Macaw.CFG (MemRepr(..))
import           Data.Macaw.Memory (Endianness(..))
import           Data.Macaw.Types (FloatType, BVType, n8, n16, n32, n64, typeWidth)
import           Data.Macaw.X86.Generator
import           Data.Macaw.X86.Monad
import           Data.Macaw.X86.X86Reg (X86Reg(..))

type BVExpr ids w = Expr ids (BVType w)
type Addr s = Expr s (BVType 64)

byteMemRepr :: MemRepr (BVType 8)
byteMemRepr = BVMemRepr (knownNat :: NatRepr 1) LittleEndian

wordMemRepr :: MemRepr (BVType 16)
wordMemRepr = BVMemRepr (knownNat :: NatRepr 2) LittleEndian

dwordMemRepr :: MemRepr (BVType 32)
dwordMemRepr = BVMemRepr (knownNat :: NatRepr 4) LittleEndian

qwordMemRepr :: MemRepr (BVType 64)
qwordMemRepr = BVMemRepr (knownNat :: NatRepr 8) LittleEndian

xmmMemRepr :: MemRepr (BVType 128)
xmmMemRepr = BVMemRepr (knownNat :: NatRepr 16) LittleEndian

------------------------------------------------------------------------
-- Utilities

-- | Return a location from a 16-bit register
reg16Loc :: F.Reg16 -> Location addr (BVType 16)
reg16Loc = reg_low16 . X86_GP . F.reg16_reg

-- | Return a location from a 32-bit register
reg32Loc :: F.Reg32 -> Location addr (BVType 32)
reg32Loc = reg_low32 . X86_GP . F.reg32_reg

-- | Return a location from a 64-bit register
reg64Loc :: F.Reg64 -> Location addr (BVType 64)
reg64Loc = fullRegister . X86_GP

------------------------------------------------------------------------
-- Getters

-- | Calculates the address corresponding to an AddrRef
getBVAddress :: F.AddrRef -> X86Generator st ids (BVExpr ids 64)
getBVAddress ar =
  case ar of
   -- FIXME: It seems that there is no sign extension here ...
    F.Addr_32 seg m_r32 m_int_r32 i32 -> do
      base <- case m_r32 of
                Nothing -> return $! bvKLit 0
                Just r  -> get (reg32Loc r)
      scale <-
        case m_int_r32 of
          Nothing     -> return $! bvKLit 0
          Just (i, r) ->
            bvTrunc n32 . bvMul (bvLit n32 (toInteger i))
              <$> get (reg32Loc r)
      let offset = uext n64 (base `bvAdd` scale `bvAdd` bvLit n32 (toInteger (F.displacementInt i32)))
      mk_absolute seg offset
    F.IP_Offset_32 _seg _i32                 -> fail "IP_Offset_32"
    F.Offset_32    _seg _w32                 -> fail "Offset_32"
    F.Offset_64    seg w64 -> do
      mk_absolute seg (bvLit n64 (toInteger w64))
    F.Addr_64      seg m_r64 m_int_r64 i32 -> do
      base <- case m_r64 of
                Nothing -> return v0_64
                Just r  -> get (reg64Loc r)
      scale <- case m_int_r64 of
                 Nothing     -> return v0_64
                 Just (i, r) -> bvTrunc n64 . bvMul (bvLit n64 (toInteger i))
                                 <$> get (reg64Loc r)
      let offset = base `bvAdd` scale `bvAdd` bvLit n64 (toInteger i32)
      mk_absolute seg offset
    F.IP_Offset_64 seg i32 -> do
      ip_val <- get rip
      mk_absolute seg (bvAdd (bvLit n64 (toInteger i32)) ip_val)
  where
    v0_64 = bvLit n64 0
    -- | Add the segment base to compute an absolute address.
    mk_absolute :: F.Segment -> Addr ids -> X86Generator st ids (Expr ids (BVType 64))
    mk_absolute seg offset
      -- In 64-bit mode the CS, DS, ES, and SS segment registers
      -- are forced to zero, and so segmentation is a nop.
      --
      -- We could nevertheless call 'getSegmentBase' in all cases
      -- here, but that adds a lot of noise to the AST in the common
      -- case of segments other than FS or GS.
      | seg == F.CS || seg == F.DS || seg == F.ES || seg == F.SS = return offset
      -- The FS and GS segments can be non-zero based in 64-bit mode.
      | otherwise = do
        base <- getSegmentBase seg
        return $ base `bvAdd` offset

-- | Translate a flexdis address-refrence into a one-byte address.
getBV8Addr :: F.AddrRef -> X86Generator st ids (Location (Addr ids) (BVType 8))
getBV8Addr ar = (`MemoryAddr`  byteMemRepr) <$> getBVAddress ar

-- | Translate a flexdis address-refrence into a two-byte address.
getBV16Addr :: F.AddrRef -> X86Generator st ids (Location (Addr ids) (BVType 16))
getBV16Addr ar = (`MemoryAddr`  wordMemRepr) <$> getBVAddress ar

-- | Translate a flexdis address-refrence into a four-byte address.
getBV32Addr :: F.AddrRef -> X86Generator st ids (Location (Addr ids) (BVType 32))
getBV32Addr ar = (`MemoryAddr` dwordMemRepr) <$> getBVAddress ar

-- | Translate a flexdis address-refrence into a eight-byte address.
getBV64Addr :: F.AddrRef -> X86Generator st ids (Location (Addr ids) (BVType 64))
getBV64Addr ar = (`MemoryAddr` qwordMemRepr) <$> getBVAddress ar

-- | Translate a flexdis address-refrence into a sixteen-byte address.
getBV128Addr :: F.AddrRef -> X86Generator st ids (Location (Addr ids) (BVType 128))
getBV128Addr ar = (`MemoryAddr` xmmMemRepr) <$> getBVAddress ar

readBVAddress :: F.AddrRef -> MemRepr tp -> X86Generator st ids (Expr ids tp)
readBVAddress ar repr = get . (`MemoryAddr` repr) =<< getBVAddress ar

-- | A bitvector value with a width that satisfies `SupportedBVWidth`.
data SomeBV v where
  SomeBV :: SupportedBVWidth n => v (BVType n) -> SomeBV v

-- | Extract the location of a bitvector value.
getSomeBVLocation :: F.Value -> X86Generator st ids (SomeBV (Location (Addr ids)))
getSomeBVLocation v =
  case v of
    F.ControlReg cr  -> pure $ SomeBV $ ControlReg cr
    F.DebugReg dr    -> pure $ SomeBV $ DebugReg dr
    F.MMXReg mmx     -> pure $ SomeBV $ x87reg_mmx $ X87_FPUReg mmx
    F.XMMReg xmm     -> pure $ SomeBV $ fullRegister $ X86_XMMReg xmm
    F.SegmentValue s -> pure $ SomeBV $ SegmentReg s
    F.X87Register i -> mk (X87StackRegister i)
    F.FarPointer _      -> fail "FarPointer"
    -- SomeBV . (`MemoryAddr`   byteMemRepr) <$> getBVAddress ar -- FIXME: what size here?
    F.VoidMem _  -> fail "VoidMem"
    F.Mem8   ar  -> SomeBV <$> getBV8Addr   ar
    F.Mem16  ar  -> SomeBV <$> getBV16Addr  ar
    F.Mem32  ar  -> SomeBV <$> getBV32Addr  ar
    F.Mem64  ar  -> SomeBV <$> getBV64Addr  ar
    F.Mem128 ar  -> SomeBV <$> getBV128Addr ar
    F.FPMem32 ar -> getBVAddress ar >>= mk . (`MemoryAddr` (floatMemRepr SingleFloatRepr))
    F.FPMem64 ar -> getBVAddress ar >>= mk . (`MemoryAddr` (floatMemRepr DoubleFloatRepr))
    F.FPMem80 ar -> getBVAddress ar >>= mk . (`MemoryAddr` (floatMemRepr X86_80FloatRepr))
    F.ByteReg  r
      | Just r64 <- F.is_low_reg r  -> mk (reg_low8  $ X86_GP r64)
      | Just r64 <- F.is_high_reg r -> mk (reg_high8 $ X86_GP r64)
      | otherwise                   -> fail "unknown r8"
    F.WordReg  r -> mk (reg16Loc r)
    F.DWordReg r -> mk (reg32Loc r)
    F.QWordReg r -> mk (reg64Loc r)
    F.ByteImm  _ -> noImm
    F.WordImm  _ -> noImm
    F.DWordImm _ -> noImm
    F.QWordImm _ -> noImm
    F.JumpOffset{}  -> fail "Jump Offset is not a location."
  where
    noImm :: Monad m => m a
    noImm = fail "Immediate is not a location"
    mk :: (Applicative m, SupportedBVWidth n) => f (BVType n) -> m (SomeBV f)
    mk = pure . SomeBV

-- | Translate a flexdis value to a location with a particular width.
getBVLocation :: F.Value -> NatRepr n -> X86Generator st ids (Location (Addr ids) (BVType n))
getBVLocation l expected = do
  SomeBV v <- getSomeBVLocation l
  case testEquality (typeWidth v) expected of
    Just Refl ->
      return v
    Nothing ->
      fail $ "Widths aren't equal: " ++ show (typeWidth v) ++ " and " ++ show expected

-- | Return a bitvector value.
getSomeBVValue :: F.Value -> X86Generator st ids (SomeBV (Expr ids))
getSomeBVValue v =
  case v of
    F.ByteImm  w        -> return $ SomeBV $ bvLit n8  $ toInteger w
    F.WordImm  w        -> return $ SomeBV $ bvLit n16 $ toInteger w
    F.DWordImm w        -> return $ SomeBV $ bvLit n32 $ toInteger w
    F.QWordImm w        -> return $ SomeBV $ bvLit n64 $ toInteger w
    F.JumpOffset _ off  -> return $ SomeBV $ bvLit n64 $ toInteger off
    _ -> do
      SomeBV l <- getSomeBVLocation v
      SomeBV <$> get l

-- | Translate a flexdis value to a value with a particular width.
getBVValue :: F.Value
           -> NatRepr n
           -> X86Generator st ids (Expr ids (BVType n))
getBVValue val expected = do
  SomeBV v <- getSomeBVValue val
  case testEquality (bv_width v) expected of
    Just Refl -> return v
    Nothing ->
      fail $ "Widths aren't equal: " ++ show (bv_width v) ++ " and " ++ show expected

-- | Get a value with the given width, sign extending as necessary.
getSignExtendedValue :: forall st ids w
                     .  1 <= w
                     => F.Value
                     -> NatRepr w
                     -> X86Generator st ids (Expr ids (BVType w))
getSignExtendedValue v out_w =
  case v of
    -- If an instruction can take a VoidMem, it needs to get it explicitly
    F.VoidMem _ar -> fail "VoidMem"
    F.Mem8   ar   -> mk =<< getBV8Addr ar
    F.Mem16  ar   -> mk =<< getBV16Addr ar
    F.Mem32  ar   -> mk =<< getBV32Addr ar
    F.Mem64  ar   -> mk =<< getBV64Addr ar
    F.Mem128 ar   -> mk =<< getBV128Addr ar

    F.ByteReg  r
      | Just r64 <- F.is_low_reg r  -> mk (reg_low8  $ X86_GP r64)
      | Just r64 <- F.is_high_reg r -> mk (reg_high8 $ X86_GP r64)
      | otherwise                   -> fail "unknown r8"
    F.WordReg  r                    -> mk (reg16Loc r)
    F.DWordReg r                    -> mk (reg32Loc r)
    F.QWordReg r                    -> mk (reg64Loc r)
    F.XMMReg r                      -> mk (fullRegister $ X86_XMMReg r)

    F.ByteImm  i                    -> return $! bvLit out_w (toInteger i)
    F.WordImm  i                    -> return $! bvLit out_w (toInteger i)
    F.DWordImm i                    -> return $! bvLit out_w (toInteger i)
    F.QWordImm i                    -> return $! bvLit out_w (toInteger i)

    _ -> fail $ "getSignExtendedValue given unexpected width: " ++ show v
  where
    -- FIXME: what happens with signs etc?
    mk :: forall u
       .  (1 <= u, KnownNat u)
       => Location (Addr ids) (BVType u)
       -> X86Generator st ids (BVExpr ids w)
    mk l
      | Just LeqProof <- testLeq (knownNat :: NatRepr u) out_w =
        sext out_w <$> get l
      | otherwise =
        fail $ "getSignExtendedValue given bad value."

truncateBVValue :: (Monad m, IsValue v, 1 <= n)
                => NatRepr n
                -> SomeBV v
                -> m (v (BVType n))
truncateBVValue n (SomeBV v)
  | Just LeqProof <- testLeq n (bv_width v) = do
      return (bvTrunc n v)
  | otherwise =
    fail $ "Widths isn't >=: " ++ show (bv_width v) ++ " and " ++ show n

-- | Return the target of a call or jump instruction.
getJumpTarget :: F.Value
              -> X86Generator st ids (BVExpr ids 64)
getJumpTarget v =
  case v of
    F.Mem64 ar -> get =<< getBV64Addr ar
    F.QWordReg r -> get (reg64Loc r)
    F.JumpOffset _ off -> bvAdd (bvLit n64 (toInteger off)) <$> get rip
    _ -> fail "Unexpected argument"

------------------------------------------------------------------------
-- Floating point

-- | This describes a floating point value including the type.
data FPLocation ids flt = FPLocation (FloatInfoRepr flt) (Location (Expr ids (BVType 64)) (FloatType flt))

-- | This describes a floating point value including the type.
data FPValue ids flt = FPValue (FloatInfoRepr flt) (Expr ids (FloatType flt))

readFPLocation :: FPLocation ids flt -> X86Generator st ids (FPValue ids flt)
readFPLocation (FPLocation repr l) = FPValue repr <$>  get l

-- | Read an address as a floating point vlaue
getFPAddrLoc :: FloatInfoRepr flt -> F.AddrRef -> X86Generator st ids (FPLocation ids flt)
getFPAddrLoc fir f_addr = do
  FPLocation fir . (`MemoryAddr` (floatMemRepr fir))
    <$> getBVAddress f_addr

-- | Get a floating point value from the argument.
getFPLocation :: F.Value -> X86Generator st ids (Some (FPLocation ids))
getFPLocation v =
  case v of
    F.FPMem32 ar -> Some <$> getFPAddrLoc SingleFloatRepr ar
    F.FPMem64 ar -> Some <$> getFPAddrLoc DoubleFloatRepr ar
    F.FPMem80 ar -> Some <$> getFPAddrLoc X86_80FloatRepr ar
    F.X87Register n -> pure $ Some $ FPLocation X86_80FloatRepr (X87StackRegister n)
    _ -> fail $ "Bad floating point argument."

-- | Get a floating point value from the argument.
getFPValue :: F.Value -> X86Generator st ids (Some (FPValue ids))
getFPValue v = getFPLocation v >>= \(Some l) -> Some <$> readFPLocation l

------------------------------------------------------------------------
-- Standard memory values

data HasRepSize f w = HasRepSize { _ppvWidth :: !(RepValSize w)
                                 , _ppvValue :: !(f (BVType w))
                                 }

-- | Gets the location to store the value poped from.
-- These functions only support general purpose registers/addresses and segments.
getAddrRegOrSegment :: F.Value -> X86Generator st ids (Some (HasRepSize (Location (Addr ids))))
getAddrRegOrSegment v =
  case v of
    F.SegmentValue s -> pure $ Some $ HasRepSize WordRepVal (SegmentReg s)
    F.Mem8  ar -> Some . HasRepSize  ByteRepVal <$> getBV8Addr  ar
    F.Mem16 ar -> Some . HasRepSize  WordRepVal <$> getBV16Addr ar
    F.Mem32 ar -> Some . HasRepSize DWordRepVal <$> getBV32Addr ar
    F.Mem64 ar -> Some . HasRepSize QWordRepVal <$> getBV64Addr ar

    F.ByteReg  r
      | Just r64 <- F.is_low_reg r  -> pure $ Some $ HasRepSize  ByteRepVal (reg_low8 $ X86_GP r64)
      | Just r64 <- F.is_high_reg r -> pure $ Some $ HasRepSize  ByteRepVal (reg_high8 $ X86_GP r64)
      | otherwise                   -> fail "unknown r8"
    F.WordReg  r                    -> pure $ Some $ HasRepSize  WordRepVal (reg16Loc r)
    F.DWordReg r                    -> pure $ Some $ HasRepSize DWordRepVal (reg32Loc r)
    F.QWordReg r                    -> pure $ Some $ HasRepSize QWordRepVal (reg64Loc r)
    _  -> fail $ "Argument " ++ show v ++ " not supported."

-- | Gets a value that can be pushed.
-- These functions only support general purpose registers/addresses and segments.
getAddrRegSegmentOrImm :: F.Value -> X86Generator st ids (Some (HasRepSize (Expr ids)))
getAddrRegSegmentOrImm v =
  case v of
    F.ByteImm  w -> return $ Some $ HasRepSize ByteRepVal  $ bvLit n8  (toInteger w)
    F.WordImm  w -> return $ Some $ HasRepSize WordRepVal  $ bvLit n16 (toInteger w)
    F.DWordImm w -> return $ Some $ HasRepSize DWordRepVal $ bvLit n32 (toInteger w)
    F.QWordImm w -> return $ Some $ HasRepSize QWordRepVal $ bvLit n64 (toInteger w)
    _ -> do
      Some (HasRepSize rep l) <- getAddrRegOrSegment v
      Some . HasRepSize rep <$> get l

------------------------------------------------------------------------
-- SSE

-- | Get a XMM value
readXMMValue :: F.Value -> X86Generator st ids (Expr ids (BVType 128))
readXMMValue (F.XMMReg r) = getReg $ X86_XMMReg r
readXMMValue (F.Mem128 a) = readBVAddress a xmmMemRepr
readXMMValue _ = fail "XMM Instruction given unexpected value."

-- | Get the low 32-bits out of an XMM register or a 64-bit XMM address.
readXMMOrMem32 :: F.Value -> X86Generator st ids (Expr ids (BVType 32))
readXMMOrMem32 (F.XMMReg r) = bvTrunc n32 <$> getReg (X86_XMMReg r)
readXMMOrMem32 (F.Mem128 a) = readBVAddress a dwordMemRepr
readXMMOrMem32 _ = fail "XMM Instruction given unexpected value."

-- | Get the low 64-bits out of an XMM register or a 64-bit XMM address.
readXMMOrMem64 :: F.Value -> X86Generator st ids (Expr ids (BVType 64))
readXMMOrMem64 (F.XMMReg r) = bvTrunc n64 <$> getReg (X86_XMMReg r)
readXMMOrMem64 (F.Mem128 a) = readBVAddress a qwordMemRepr
readXMMOrMem64 _ = fail "XMM Instruction given unexpected value."
