{-
Copyright        : (c) Galois, Inc 2015-2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>, Simon Winwood <sjw@galois.com>

This defines a type for representing what Reopt considers registers on
X86_64.
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
module Data.Macaw.X86.X86Reg
  ( ProgramCounter
  , GP
  , Flag
  , Segment
  , Control
  , Debug

  , X87_FPU
  , X87_Status
  , X87_Top
  , X87_Tag
  , X87_ControlMask
  , X87_Control
  , XMM

    -- * X86Reg
  , X86Reg(..)

  , BitConversion(..)
  , BitPacking(..)
--  , registerWidth

  , x87StatusNames
    -- * General purpose registers
  , pattern RAX
  , pattern RBX
  , pattern RCX
  , pattern RDX
  , pattern RSI
  , pattern RDI
  , pattern RSP
  , pattern RBP
  , pattern R8
  , pattern R9
  , pattern R10
  , pattern R11
  , pattern R12
  , pattern R13
  , pattern R14
  , pattern R15
    -- * X86 Flags
  , pattern CF
  , pattern PF
  , pattern AF
  , pattern ZF
  , pattern SF
  , pattern TF
  , pattern IF
  , pattern DF
  , pattern OF
    -- * X87 status flags
  , pattern X87_IE
  , pattern X87_DE
  , pattern X87_ZE
  , pattern X87_OE
  , pattern X87_UE
  , pattern X87_PE
  , pattern X87_EF
  , pattern X87_ES
  , pattern X87_C0
  , pattern X87_C1
  , pattern X87_C2
  , pattern X87_C3
    -- * Register lists
  , gpRegList
  , flagRegList
  , xmmRegList
  , x87FPURegList
  , x86StateRegs
  , x86CalleeSavedRegs
  , x86ArgumentRegs
  , x86FloatArgumentRegs
  , x86ResultRegs
  , x86FloatResultRegs
  ) where

import           Data.Macaw.CFG (RegAddrWidth, RegisterInfo(..), PrettyF(..))
import           Data.Macaw.Types
import           Data.Parameterized.Classes
import           Data.Parameterized.NatRepr
import           Data.Parameterized.Some
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Vector as V
import qualified Flexdis86 as F
import           Text.PrettyPrint.ANSI.Leijen as PP hiding ((<$>))

import qualified Data.Macaw.X86.X86Flag as R

-- Widths of common types
type ProgramCounter  = BVType 64
type GP              = BVType 64
type Flag            = BoolType
type Segment         = BVType 16
type Control         = BVType 64
type Debug           = BVType 64
type X87_FPU         = BVType 80
type X87_Status      = BoolType
type X87_Top         = BVType 3
type X87_Tag         = BVType 2
type X87_ControlMask = BVType 1
type X87_Control     = BVType 2
type XMM             = BVType 128

------------------------------------------------------------------------
-- X86Reg

-- The datatype for x86 registers.
data X86Reg tp
   = (tp ~ BVType 64)  => X86_IP
     -- | One of 16 general purpose registers
   | (tp ~ BVType 64)  => X86_GP {-# UNPACK #-} !F.Reg64
     -- | One of 32 initial flag registers.
   | (tp ~ BoolType)   => X86_FlagReg {-# UNPACK #-} !R.X86Flag
     -- | One of 16 x87 status registers
   | (tp ~ BoolType)   => X87_StatusReg {-# UNPACK #-} !Int
     -- | X87 tag register.
   | (tp ~ BVType 3)   => X87_TopReg
     -- X87 tag register.
   | (tp ~ BVType 2)   => X87_TagReg {-# UNPACK #-} !Int
      -- One of 8 fpu/mmx registers.
   | (tp ~ BVType 80)  => X87_FPUReg {-#UNPACK #-} !F.MMXReg
     -- One of 8 XMM registers
   | (tp ~ BVType 128) => X86_XMMReg !F.XMMReg

instance Show (X86Reg tp) where
  show X86_IP          = "rip"
  show (X86_GP r)      = show r
  show (X86_FlagReg r) = show r
  show (X87_StatusReg r) = nm
    where Just nm = x87StatusNames V.!? r
  show X87_TopReg      = "x87top"
  show (X87_TagReg n)  = "tag" ++ show n
  show (X87_FPUReg r)  = show r
  show (X86_XMMReg r)  = show r

instance ShowF X86Reg where
  showF = show

instance PrettyF X86Reg where
  prettyF = text . show

instance TestEquality X86Reg where
  testEquality x y = orderingIsEqual (compareF x y)
    where
      -- FIXME: copied from Representation.hs, move
      orderingIsEqual :: OrderingF (x :: k) (y :: k) -> Maybe (x :~: y)
      orderingIsEqual o =
        case o of
         LTF -> Nothing
         EQF -> Just Refl
         GTF -> Nothing

instance Eq (X86Reg tp) where
  r == r'
    | Just _ <- testEquality r r' = True
    | otherwise = False

instance OrdF X86Reg where
  compareF X86_IP            X86_IP            = EQF
  compareF X86_IP            _                 = LTF
  compareF _                 X86_IP            = GTF

  compareF (X86_GP n)        (X86_GP n')        = fromOrdering (compare n n')
  compareF X86_GP{}           _                 = LTF
  compareF _                 X86_GP{}           = GTF

  compareF (X86_FlagReg n)   (X86_FlagReg n')   = fromOrdering (compare n n')
  compareF X86_FlagReg{}         _              = LTF
  compareF _                 X86_FlagReg{}      = GTF

  compareF (X87_StatusReg n) (X87_StatusReg n') = fromOrdering (compare n n')
  compareF X87_StatusReg{}    _                 = LTF
  compareF _                 X87_StatusReg{}    = GTF

  compareF X87_TopReg         X87_TopReg        = EQF
  compareF X87_TopReg         _                 = LTF
  compareF _                 X87_TopReg         = GTF

  compareF (X87_TagReg n)     (X87_TagReg n')     = fromOrdering (compare n n')
  compareF X87_TagReg{}       _                  = LTF
  compareF _                 X87_TagReg{}        = GTF

  compareF (X87_FPUReg n)     (X87_FPUReg n')     = fromOrdering (compare n n')
  compareF X87_FPUReg{}       _                  = LTF
  compareF _                 X87_FPUReg{}        = GTF

  compareF (X86_XMMReg n)        (X86_XMMReg n')        = fromOrdering (compare n n')

instance Ord (X86Reg cl) where
  a `compare` b = case a `compareF` b of
    GTF -> GT
    EQF -> EQ
    LTF -> LT

instance HasRepr X86Reg TypeRepr where
  typeRepr r =
    case r of
      X86_IP           -> knownType
      X86_GP{}         -> knownType
      X86_FlagReg{}    -> knownType
      X87_StatusReg{}  -> knownType
      X87_TopReg       -> knownType
      X87_TagReg{}     -> knownType
      X87_FPUReg{}     -> knownType
      X86_XMMReg{}     -> knownType

{-
registerWidth :: X86Reg tp -> NatRepr (TypeBits tp)
registerWidth X86_IP           = knownNat
registerWidth X86_GP{}         = knownNat
registerWidth X86_FlagReg{}    = knownNat
registerWidth X87_StatusReg{}  = knownNat
registerWidth X87_TopReg       = knownNat
registerWidth X87_TagReg{}     = knownNat
registerWidth X87_FPUReg{}     = knownNat
registerWidth X86_XMMReg{}     = knownNat
-}

------------------------------------------------------------------------
-- Exported constructors and their conversion to words

-- | A description of how a sub-word may be extracted from a word. If a bit isn't
-- constant or from a register it is reserved.
data BitConversion n = forall m n'. (1 <= n', n' <= n)
                       => RegisterBit (X86Reg (BVType n')) (NatRepr m)
                     | forall m. (m + 1 <= n) => ConstantBit Bool (NatRepr m)

-- | A description of how a particular status word is packed/unpacked into sub-bits
data BitPacking (n :: Nat) = BitPacking (NatRepr n) [BitConversion n]

------------------------------------------------------------------------
-- General purpose register aliases.

pattern RAX :: X86Reg GP
pattern RAX = X86_GP F.RAX

pattern RBX :: X86Reg GP
pattern RBX = X86_GP F.RBX

pattern RCX :: X86Reg GP
pattern RCX = X86_GP F.RCX

pattern RDX :: X86Reg GP
pattern RDX = X86_GP F.RDX

pattern RSI :: X86Reg GP
pattern RSI = X86_GP F.RSI

pattern RDI :: X86Reg GP
pattern RDI = X86_GP F.RDI

pattern RSP :: X86Reg GP
pattern RSP = X86_GP F.RSP

pattern RBP :: X86Reg GP
pattern RBP = X86_GP F.RBP

pattern R8  :: X86Reg GP
pattern R8  = X86_GP F.R8

pattern R9  :: X86Reg GP
pattern R9  = X86_GP F.R9

pattern R10 :: X86Reg GP
pattern R10 = X86_GP F.R10

pattern R11 :: X86Reg GP
pattern R11 = X86_GP F.R11

pattern R12 :: X86Reg GP
pattern R12 = X86_GP F.R12

pattern R13 :: X86Reg GP
pattern R13 = X86_GP F.R13

pattern R14 :: X86Reg GP
pattern R14 = X86_GP F.R14

pattern R15 :: X86Reg GP
pattern R15 = X86_GP F.R15

pattern CF :: X86Reg Flag
pattern CF = X86_FlagReg R.CF

pattern PF :: X86Reg Flag
pattern PF = X86_FlagReg R.PF

pattern AF :: X86Reg Flag
pattern AF = X86_FlagReg R.AF

pattern ZF :: X86Reg Flag
pattern ZF = X86_FlagReg R.ZF

pattern SF :: X86Reg Flag
pattern SF = X86_FlagReg R.SF

pattern TF :: X86Reg Flag
pattern TF = X86_FlagReg R.TF

pattern IF :: X86Reg Flag
pattern IF = X86_FlagReg R.IF

pattern DF :: X86Reg Flag
pattern DF = X86_FlagReg R.DF

pattern OF :: X86Reg Flag
pattern OF = X86_FlagReg R.OF

-- | x87 flags
pattern X87_IE :: X86Reg X87_Status
pattern X87_IE = X87_StatusReg 0

pattern X87_DE :: X86Reg X87_Status
pattern X87_DE = X87_StatusReg 1

pattern X87_ZE :: X86Reg X87_Status
pattern X87_ZE = X87_StatusReg 2

pattern X87_OE :: X86Reg X87_Status
pattern X87_OE = X87_StatusReg 3

pattern X87_UE :: X86Reg X87_Status
pattern X87_UE = X87_StatusReg 4

pattern X87_PE :: X86Reg X87_Status
pattern X87_PE = X87_StatusReg 5

pattern X87_EF :: X86Reg X87_Status
pattern X87_EF = X87_StatusReg 6

pattern X87_ES :: X86Reg X87_Status
pattern X87_ES = X87_StatusReg 7

pattern X87_C0 :: X86Reg X87_Status
pattern X87_C0 = X87_StatusReg 8

pattern X87_C1 :: X86Reg X87_Status
pattern X87_C1 = X87_StatusReg 9

pattern X87_C2 :: X86Reg X87_Status
pattern X87_C2 = X87_StatusReg 10

pattern X87_C3 :: X86Reg X87_Status
pattern X87_C3 = X87_StatusReg 14

x87StatusNames :: V.Vector String
x87StatusNames = V.fromList $
  [ "ie", "de", "ze", "oe",       "ue",       "pe",       "ef", "es"
  , "c0", "c1", "c2", "RESERVED", "RESERVED", "RESERVED", "c3", "RESERVED"
  ]

------------------------------------------------------------------------
-- RegisterInfo instance

-- | The ABI defines these (http://www.x86-64.org/documentation/abi.pdf)
-- Syscalls clobber rcx and r11, but we don't really care about these anyway.
x86SyscallArgumentRegs :: [ X86Reg (BVType 64) ]
x86SyscallArgumentRegs = [ RDI, RSI, RDX, R10, R8, R9 ]

gpRegList :: [X86Reg (BVType 64)]
gpRegList = [X86_GP (F.reg64 i) | i <- [0..15]]

flagRegList :: [X86Reg BoolType]
flagRegList = X86_FlagReg <$> R.flagList

x87StatusRegList :: [X86Reg BoolType]
x87StatusRegList = [X87_StatusReg i | i <- [0..15]]

x87TagRegList :: [X86Reg (BVType 2)]
x87TagRegList = [X87_TagReg i | i <- [0..7]]

x87FPURegList :: [X86Reg (BVType 80)]
x87FPURegList = [X87_FPUReg (F.mmxReg i) | i <- [0..7]]

xmmRegList :: [X86Reg (BVType 128)]
xmmRegList = [X86_XMMReg (F.xmmReg i) | i <- [0..15]]

-- | List of registers stored in X86State
x86StateRegs :: [Some X86Reg]
x86StateRegs
  =  [Some X86_IP]
  ++ (Some <$> gpRegList)
  ++ (Some <$> flagRegList)
  ++ (Some <$> x87StatusRegList)
  ++ [Some X87_TopReg]
  ++ (Some <$> x87TagRegList)
  ++ (Some <$> x87FPURegList)
  ++ (Some <$> xmmRegList)

type instance RegAddrWidth X86Reg = 64

instance RegisterInfo X86Reg where
  archRegs = x86StateRegs

  ip_reg = X86_IP
  sp_reg = RSP

  -- The register used to store system call numbers.
  syscall_num_reg = RAX

  -- The ABI defines these (http://www.x86-64.org/documentation/abi.pdf)
  -- Syscalls clobber rcx and r11, but we don't really care about these
  -- anyway.
  syscallArgumentRegs = x86SyscallArgumentRegs


------------------------------------------------------------------------
-- Register information

-- | List of registers that a callee must save.
x86CalleeSavedRegs :: Set (Some X86Reg)
x86CalleeSavedRegs = Set.fromList $
  [ -- Some rsp sjw: rsp is special
    Some RBP
  , Some RBX
  , Some R12
  , Some R13
  , Some R14
  , Some R15
  , Some DF
  , Some X87_TopReg
  ]

x86ArgumentRegs :: [X86Reg (BVType 64)]
x86ArgumentRegs = [ RDI, RSI, RDX, RCX, R8, R9 ]

x86FloatArgumentRegs :: [X86Reg (BVType 128)]
x86FloatArgumentRegs =  X86_XMMReg . F.xmmReg <$> [0..7]

x86ResultRegs :: [X86Reg (BVType 64)]
x86ResultRegs = [ RAX, RDX ]

x86FloatResultRegs :: [X86Reg (BVType 128)]
x86FloatResultRegs = [ X86_XMMReg (F.xmmReg 0) ]
