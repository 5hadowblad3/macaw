{-|
Copyright        : (c) Galois, Inc 2015-2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>

This defines the core operations for mapping from Reopt to Crucible.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE PatternGuards #-}
module Data.Macaw.Symbolic.CrucGen
  ( MacawSymbolicArchFunctions(..)
  , crucArchRegTypes
  , MacawExt
  , MacawExprExtension(..)
  , MacawOverflowOp(..)
  , MacawStmtExtension(..)
  , MacawFunctionArgs
  , MacawFunctionResult
  , ArchAddrCrucibleType
  , MacawCrucibleRegTypes
  , ArchRegStruct
  , MacawArchConstraints
  , MacawArchStmtExtension
    -- ** Operations for implementing new backends.
  , CrucGen
  , MacawMonad
  , runMacawMonad
  , addMacawBlock
  , BlockLabelMap
  , addParsedBlock
  , nextStatements
  , valueToCrucible
  , evalArchStmt
  , MemSegmentMap
  , lemma1_16
    -- * Additional exports
  , runCrucGen
  , setMachineRegs
  , addTermStmt
  , parsedBlockLabel
  ) where

import           Control.Lens hiding (Empty, (:>))
import           Control.Monad.Except
import           Control.Monad.ST
import           GHC.TypeLits(KnownNat)
import           Control.Monad.State.Strict
import           Data.Bits
import qualified Data.Macaw.CFG as M
import qualified Data.Macaw.CFG.Block as M
import qualified Data.Macaw.Discovery.State as M
import qualified Data.Macaw.Types as M
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Parameterized.Classes
import           Data.Parameterized.NatRepr
import           Data.Parameterized.Context as Ctx
import           Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.TraversableFC
import qualified Data.Parameterized.TH.GADT as U


import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Text as Text
import           Data.Word
import qualified Lang.Crucible.CFG.Expr as C
import qualified Lang.Crucible.CFG.Reg as CR
import           Lang.Crucible.ProgramLoc as C
import qualified Lang.Crucible.Solver.Symbol as C
import qualified Lang.Crucible.Types as C

import qualified Lang.Crucible.LLVM.MemModel as MM

import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import           Data.Macaw.Symbolic.PersistentState


-- | List of crucible types for architecture.
type MacawCrucibleRegTypes (arch :: *) = CtxToCrucibleType (ArchRegContext arch)

type ArchRegStruct (arch :: *) = C.StructType (MacawCrucibleRegTypes arch)

type ArchAddrCrucibleType arch = MM.LLVMPointerType (M.ArchAddrWidth arch)

type MacawFunctionArgs arch = EmptyCtx ::> ArchRegStruct arch
type MacawFunctionResult arch = ArchRegStruct arch

type family MacawArchStmtExtension (arch :: *) :: (C.CrucibleType -> *) -> C.CrucibleType -> *

type MacawArchConstraints arch =
  ( TraversableFC (MacawArchStmtExtension arch)
  , C.TypeApp (MacawArchStmtExtension arch)
  , C.PrettyApp (MacawArchStmtExtension arch)
  , KnownNat (M.ArchAddrWidth arch)
  , 16 <= M.ArchAddrWidth arch
  )

------------------------------------------------------------------------
-- CrucPersistentState


-- | Architecture-specific information needed to translate from Macaw to Crucible
data MacawSymbolicArchFunctions arch
  = MacawSymbolicArchFunctions
  { crucGenArchConstraints
    :: !(forall a . ((M.RegisterInfo (M.ArchReg arch), MacawArchConstraints arch) => a) -> a)
  , crucGenRegAssignment :: !(Ctx.Assignment (M.ArchReg arch) (ArchRegContext arch))
    -- ^ Map from indices in the ArchRegContext to the associated register.
  , crucGenArchRegName :: !(forall tp . M.ArchReg arch tp -> C.SolverSymbol)
    -- ^ Provides a solver name to use for referring to register.
  , crucGenArchFn :: !(forall ids s tp
                         . M.ArchFn arch (M.Value arch ids) tp
                         -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp)))
     -- ^ Generate crucible for architecture-specific function.
  , crucGenArchStmt
    :: !(forall ids s . M.ArchStmt arch (M.Value arch ids) -> CrucGen arch ids s ())
     -- ^ Generate crucible for architecture-specific statement.
  , crucGenArchTermStmt :: !(forall ids s
                               . M.ArchTermStmt arch ids
                               -> M.RegState (M.ArchReg arch) (M.Value arch ids)
                               -> CrucGen arch ids s ())
     -- ^ Generate crucible for architecture-specific terminal statement.
  }

-- | Return types of registers in Crucible
crucArchRegTypes ::
  MacawSymbolicArchFunctions arch ->
  Assignment C.TypeRepr (CtxToCrucibleType (ArchRegContext arch))
crucArchRegTypes archFns = crucGenArchConstraints archFns $
    typeCtxToCrucible (fmapFC M.typeRepr regAssign)
  where regAssign = crucGenRegAssignment archFns

------------------------------------------------------------------------
-- MacawExprExtension

data MacawOverflowOp
   = Uadc
   | Sadc
   | Usbb
   | Ssbb
  deriving (Eq, Ord, Show)

type BVPtr a       = MM.LLVMPointerType (M.ArchAddrWidth a)
type ArchNatRepr a = NatRepr (M.ArchAddrWidth a)

data MacawExprExtension (arch :: *)
                        (f :: C.CrucibleType -> *)
                        (tp :: C.CrucibleType)
  where
  MacawOverflows :: (1 <= w)
                 => !MacawOverflowOp
                 -> !(NatRepr w)
                 -> !(f (C.BVType w))
                 -> !(f (C.BVType w))
                 -> !(f C.BoolType)
                 -> MacawExprExtension arch f C.BoolType

  -- | Treat a pointer as a number.
  PtrToBits ::
    (1 <= w) =>
    !(NatRepr w) ->
    !(f (MM.LLVMPointerType w)) ->
    MacawExprExtension arch f (C.BVType w)

  -- | Treat a number as a pointer.
  -- We can never read from this pointer.
  BitsToPtr ::
    (1 <= w) =>
    !(NatRepr w) ->
    !(f (C.BVType w)) ->
    MacawExprExtension arch f (MM.LLVMPointerType w)

  -- | A null pointer.
  MacawNullPtr ::
    (16 <= M.ArchAddrWidth arch) =>
    !(ArchNatRepr arch) ->
    MacawExprExtension arch f (BVPtr arch)


instance C.PrettyApp (MacawExprExtension arch) where
  ppApp f a0 =
    case a0 of
      MacawOverflows o w x y c ->
        let mnem = "macawOverflows_" ++ show o ++ "_" ++ show w
         in sexpr mnem [f x, f y, f c]

      PtrToBits w x  -> sexpr ("ptr_to_bits_" ++ show w) [f x]
      BitsToPtr w x  -> sexpr ("bits_to_ptr_" ++ show w) [f x]

      MacawNullPtr _ -> sexpr "null_ptr" []

instance C.TypeApp (MacawExprExtension arch) where
  appType x =
    case x of
      MacawOverflows {}     -> C.knownRepr
      PtrToBits w _         -> C.BVRepr w
      BitsToPtr w _         -> MM.LLVMPointerRepr w
      MacawNullPtr w | LeqProof <- lemma1_16 w     -> MM.LLVMPointerRepr w


------------------------------------------------------------------------
-- MacawStmtExtension

data MacawStmtExtension (arch :: *)
                        (f    :: C.CrucibleType -> *)
                        (tp   :: C.CrucibleType)
  where

  -- | Read from memory.
  MacawReadMem ::
    (16 <= M.ArchAddrWidth arch) =>

    !(ArchNatRepr arch) ->

    -- | Info about memory (endianness, size)
    !(M.MemRepr tp) ->

    -- | Pointer to read from.
    !(f (ArchAddrCrucibleType arch)) ->

    MacawStmtExtension arch f (ToCrucibleType tp)


  -- | Read from memory, if the condition is True.
  -- Otherwise, just return the given value.
  MacawCondReadMem ::
    (16 <= M.ArchAddrWidth arch) =>

    !(ArchNatRepr arch) ->

    -- | Info about memory (endianness, size)
    !(M.MemRepr tp) ->

    -- | Condition
    !(f C.BoolType) ->

    -- | Pointer to read from
    !(f (ArchAddrCrucibleType arch)) ->

    -- | Default value, returned if the condition is False.
    !(f (ToCrucibleType tp)) ->

    MacawStmtExtension arch f (ToCrucibleType tp)

  -- | Write to memory
  MacawWriteMem ::
    (16 <= M.ArchAddrWidth arch) =>
    !(ArchNatRepr arch) ->
    !(M.MemRepr tp) ->
    !(f (ArchAddrCrucibleType arch)) ->
    !(f (ToCrucibleType tp)) ->
    MacawStmtExtension arch f C.UnitType

  -- | Get the pointer associated with the given global address.
  MacawGlobalPtr ::
    (16 <= M.ArchAddrWidth arch, M.MemWidth (M.ArchAddrWidth arch)) =>
    !(M.MemAddr (M.ArchAddrWidth arch)) ->
    MacawStmtExtension arch f (BVPtr arch)


  -- | Generate a fresh symbolic variable of the given type.
  MacawFreshSymbolic ::
    !(M.TypeRepr tp) -> MacawStmtExtension arch f (ToCrucibleType tp)

  -- | Call a function.
  MacawCall ::
    -- | Types of fields in register struct
    !(Assignment C.TypeRepr (CtxToCrucibleType (ArchRegContext arch))) ->

    -- | Arguments to call.
    !(f (ArchRegStruct arch)) ->

    MacawStmtExtension arch f (ArchRegStruct arch)

  -- | A machine instruction.
  MacawArchStmtExtension ::
    !(MacawArchStmtExtension arch f tp) ->
    MacawStmtExtension arch f tp

  -- NOTE: The Ptr* operations below are statements and not expressions
  -- because they need to read the memory variable, to determine if their
  -- inputs are valid pointers.

  -- | Equality for pointer or bit-vector.
  PtrEq ::
    (16 <= M.ArchAddrWidth arch) =>
    !(ArchNatRepr arch) ->
    !(f (BVPtr arch)) ->
    !(f (BVPtr arch)) ->
    MacawStmtExtension arch f C.BoolType

  -- | Unsigned comparison for pointer/bit-vector.
  PtrLeq ::
    (16 <= M.ArchAddrWidth arch) =>
    !(ArchNatRepr arch) ->
    !(f (BVPtr arch)) ->
    !(f (BVPtr arch)) ->
    MacawStmtExtension arch f C.BoolType

  -- | Unsigned comparison for pointer/bit-vector.
  PtrLt ::
    (16 <= M.ArchAddrWidth arch) =>
    !(ArchNatRepr arch) ->
    !(f (BVPtr arch)) ->
    !(f (BVPtr arch)) ->
    MacawStmtExtension arch f C.BoolType

  -- | Mux for pointers or bit-vectors.
  PtrMux ::
    (16 <= M.ArchAddrWidth arch) =>
    !(ArchNatRepr arch) ->
    !(f C.BoolType) ->
    !(f (BVPtr arch)) ->
    !(f (BVPtr arch)) ->
    MacawStmtExtension arch f (BVPtr arch)

  -- | Add a pointer to a bit-vector, or two bit-vectors.
  PtrAdd ::
    (16 <= M.ArchAddrWidth arch) =>
    !(ArchNatRepr arch) ->
    !(f (BVPtr arch)) ->
    !(f (BVPtr arch)) ->
    MacawStmtExtension arch f (BVPtr arch)

  -- | Subtract two pointers, two bit-vectors, or bit-vector from a pointer.
  PtrSub ::
    (16 <= M.ArchAddrWidth arch) =>
    !(ArchNatRepr arch) ->
    !(f (BVPtr arch)) ->
    !(f (BVPtr arch)) ->
    MacawStmtExtension arch f (BVPtr arch)



instance TraversableFC (MacawArchStmtExtension arch)
      => FunctorFC (MacawStmtExtension arch) where
  fmapFC = fmapFCDefault

instance TraversableFC (MacawArchStmtExtension arch)
      => FoldableFC (MacawStmtExtension arch) where
  foldMapFC = foldMapFCDefault




sexpr :: String -> [Doc] -> Doc
sexpr s [] = text s
sexpr s l  = parens (text s <+> hsep l)

instance C.PrettyApp (MacawArchStmtExtension arch)
      => C.PrettyApp (MacawStmtExtension arch) where
  ppApp f a0 =
    case a0 of
      MacawReadMem _ r a     -> sexpr "macawReadMem"       [pretty r, f a]
      MacawCondReadMem _ r c a d -> sexpr "macawCondReadMem" [pretty r, f c, f a, f d ]
      MacawWriteMem _ r a v  -> sexpr "macawWriteMem"      [pretty r, f a, f v]
      MacawGlobalPtr x -> sexpr "global" [ text (show x) ]

      MacawFreshSymbolic r -> sexpr "macawFreshSymbolic" [ text (show r) ]
      MacawCall _ regs -> sexpr "macawCall" [ f regs ]
      MacawArchStmtExtension a -> C.ppApp f a

      PtrEq _ x y    -> sexpr "ptr_eq" [ f x, f y ]
      PtrLt _ x y    -> sexpr "ptr_lt" [ f x, f y ]
      PtrLeq _ x y   -> sexpr "ptr_leq" [ f x, f y ]
      PtrAdd _ x y   -> sexpr "ptr_add" [ f x, f y ]
      PtrSub _ x y   -> sexpr "ptr_sub" [ f x, f y ]
      PtrMux _ c x y -> sexpr "ptr_mux" [ f c, f x, f y ]


instance C.TypeApp (MacawArchStmtExtension arch)
      => C.TypeApp (MacawStmtExtension arch) where
  appType (MacawReadMem _ r _) = memReprToCrucible r
  appType (MacawCondReadMem _ r _ _ _) = memReprToCrucible r
  appType (MacawWriteMem _ _ _ _) = C.knownRepr
  appType (MacawGlobalPtr a)
    | let w = M.addrWidthNatRepr (M.addrWidthRepr a)
    , LeqProof <- lemma1_16 w = MM.LLVMPointerRepr w
  appType (MacawFreshSymbolic r) = typeToCrucible r
  appType (MacawCall regTypes _) = C.StructRepr regTypes
  appType (MacawArchStmtExtension f) = C.appType f
  appType PtrEq {}            = C.knownRepr
  appType PtrLt {}            = C.knownRepr
  appType PtrLeq {}           = C.knownRepr
  appType (PtrAdd w _ _)   | LeqProof <- lemma1_16 w = MM.LLVMPointerRepr w
  appType (PtrSub w _ _)   | LeqProof <- lemma1_16 w = MM.LLVMPointerRepr w
  appType (PtrMux w _ _ _) | LeqProof <- lemma1_16 w = MM.LLVMPointerRepr w

lemma1_16 :: (16 <= w) => p w -> LeqProof 1 w
lemma1_16 w = leqTrans p (leqProof knownNat w)
  where
  p :: LeqProof 1 16
  p = leqProof knownNat knownNat

------------------------------------------------------------------------
-- MacawExt

data MacawExt (arch :: *)

type instance C.ExprExtension (MacawExt arch) = MacawExprExtension arch
type instance C.StmtExtension (MacawExt arch) = MacawStmtExtension arch

instance MacawArchConstraints arch
      => C.IsSyntaxExtension (MacawExt arch)

-- | Map from indices of segments without a fixed base address to a
-- global variable storing the base address.
--
-- This uses a global variable so that we can do the translation, and then
-- decide where to locate it without requiring us to also pass the values
-- around arguments.
type MemSegmentMap w = Map M.RegionIndex (CR.GlobalVar (C.BVType w))

-- | State used for generating blocks
data CrucGenState arch ids s
   = CrucGenState
   { translateFns       :: !(MacawSymbolicArchFunctions arch)
   , crucMemBaseAddrMap :: !(MemSegmentMap (M.ArchAddrWidth arch))
     -- ^ Map from memory region to base address
   , crucRegIndexMap :: !(RegIndexMap arch)
     -- ^ Map from architecture register to Crucible/Macaw index pair.
   , crucPState      :: !(CrucPersistentState ids s)
     -- ^ State that persists across blocks.
   , crucRegisterReg :: !(CR.Reg s (ArchRegStruct arch))
   , macawPositionFn :: !(M.ArchAddrWord arch -> C.Position)
     -- ^ Map from offset to Crucible position.
   , blockLabel :: (CR.Label s)
     -- ^ Label for this block we are translating
   , codeOff    :: !(M.ArchAddrWord arch)
     -- ^ Offset
   , prevStmts  :: ![C.Posd (CR.Stmt (MacawExt arch) s)]
     -- ^ List of states in reverse order
   }

crucPStateLens ::
  Simple Lens (CrucGenState arch ids s) (CrucPersistentState ids s)
crucPStateLens = lens crucPState (\s v -> s { crucPState = v })

assignValueMapLens ::
  Simple Lens (CrucPersistentState ids s)
              (MapF (M.AssignId ids) (MacawCrucibleValue (CR.Atom s)))
assignValueMapLens = lens assignValueMap (\s v -> s { assignValueMap = v })

type CrucGenRet arch ids s = (CrucGenState arch ids s, CR.TermStmt s (MacawFunctionResult arch))

newtype CrucGen arch ids s r
   = CrucGen { unCrucGen
               :: CrucGenState arch ids s
                  -> (CrucGenState arch ids s
                      -> r
                      -> ST s (CrucGenRet arch ids s))
                  -> ST s (CrucGenRet arch ids s)
             }

instance Functor (CrucGen arch ids s) where
  fmap f m = CrucGen $ \s0 cont -> unCrucGen m s0 $ \s1 v -> cont s1 (f v)

instance Applicative (CrucGen arch ids s) where
  pure r = CrucGen $ \s cont -> cont s r
  mf <*> ma = CrucGen $ \s0 cont -> unCrucGen mf s0
                      $ \s1 f -> unCrucGen ma s1
                      $ \s2 a -> cont s2 (f a)

instance Monad (CrucGen arch ids s) where
  m >>= h = CrucGen $ \s0 cont -> unCrucGen m s0 $ \s1 r -> unCrucGen (h r) s1 cont

instance MonadState (CrucGenState arch ids s) (CrucGen arch ids s) where
  get = CrucGen $ \s cont -> cont s s
  put s = CrucGen $ \_ cont -> cont s ()

-- | A NatRepr corresponding to the architecture width.
archAddrWidth :: CrucGen arch ids s (NatRepr (M.ArchAddrWidth arch))
archAddrWidth =
  do archFns <- translateFns <$> get
     crucGenArchConstraints archFns (return knownRepr)

-- | Get current position
getPos :: CrucGen arch ids s C.Position
getPos = gets $ \s -> macawPositionFn s (codeOff s)

addStmt :: CR.Stmt (MacawExt arch) s -> CrucGen arch ids s ()
addStmt stmt = seq stmt $ do
  p <- getPos
  s <- get
  let pstmt = C.Posd p stmt
  seq pstmt $ do
  put $! s { prevStmts = pstmt : prevStmts s }

addTermStmt :: CR.TermStmt s (MacawFunctionResult arch)
            -> CrucGen arch ids s a
addTermStmt tstmt = do
  CrucGen $ \s _ -> pure (s, tstmt)
{-
  let termPos = macawPositionFn s (codeOff s)
  let lbl = blockLabel s
  let stmts = Seq.fromList (reverse (prevStmts s))
  let term = C.Posd termPos tstmt
  let blk = CR.mkBlock (CR.LabelID lbl) Set.empty stmts term
  pure $ (crucPState s, blk)
-}

freshValueIndex :: CrucGen arch ids s Int
freshValueIndex = do
  s <- get
  let ps = crucPState s
  let cnt = valueCount ps
  put $! s { crucPState = ps { valueCount = cnt + 1 } }
  pure $! cnt

-- | Evaluate the crucible app and return a reference to the result.
evalAtom :: CR.AtomValue (MacawExt arch) s ctp -> CrucGen arch ids s (CR.Atom s ctp)
evalAtom av = do
  archFns <- gets translateFns
  crucGenArchConstraints archFns $ do
  p <- getPos
  i <- freshValueIndex
  -- Make atom
  let atom = CR.Atom { CR.atomPosition = p
                     , CR.atomId = i
                     , CR.atomSource = CR.Assigned
                     , CR.typeOfAtom = CR.typeOfAtomValue av
                     }
  addStmt $ CR.DefineAtom atom av
  pure $! atom

-- | Evaluate the crucible app and return a reference to the result.
crucibleValue :: C.App (MacawExt arch) (CR.Atom s) ctp -> CrucGen arch ids s (CR.Atom s ctp)
crucibleValue = evalAtom . CR.EvalApp

-- | Evaluate a Macaw expression extension
evalMacawExt :: MacawExprExtension arch (CR.Atom s) tp -> CrucGen arch ids s (CR.Atom s tp)
evalMacawExt = crucibleValue . C.ExtensionApp

-- | Treat a register value as a bit-vector.
toBits ::
  (1 <= w) =>
  NatRepr w ->
  CR.Atom s (MM.LLVMPointerType w) ->
  CrucGen arch ids s (CR.Atom s (C.BVType w))
toBits w x = evalMacawExt (PtrToBits w x)

-- | Treat a bit-vector as a register value.
fromBits ::
  (1 <= w) =>
  NatRepr w ->
  CR.Atom s (C.BVType w) ->
  CrucGen arch ids s (CR.Atom s (MM.LLVMPointerType w))
fromBits w x = evalMacawExt (BitsToPtr w x)




-- | Return the value associated with the given register
getRegValue :: M.ArchReg arch tp
            -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
getRegValue r = do
  archFns <- gets translateFns
  idxMap  <- gets crucRegIndexMap
  crucGenArchConstraints archFns $ do
  case MapF.lookup r idxMap of
    Nothing -> fail $ "internal: Register is not bound."
    Just idx -> do
      reg <- gets crucRegisterReg
      regStruct <- evalAtom (CR.ReadReg reg)
      let tp = M.typeRepr (crucGenRegAssignment archFns Ctx.! macawIndex idx)
      crucibleValue (C.GetStruct regStruct (crucibleIndex idx)
                    (typeToCrucible tp))

v2c :: M.Value arch ids tp
    -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
v2c = valueToCrucible

v2c' :: (1 <= w) =>
       NatRepr w ->
       M.Value arch ids (M.BVType w) ->
       CrucGen arch ids s (CR.Atom s (C.BVType w))
v2c' w x = toBits w =<< valueToCrucible x

-- | Evaluate the crucible app and return a reference to the result.
appAtom :: C.App (MacawExt arch) (CR.Atom s) ctp ->
            CrucGen arch ids s (CR.Atom s ctp)
appAtom app = evalAtom (CR.EvalApp app)

appBVAtom ::
  (1 <= w) =>
  NatRepr w ->
  C.App (MacawExt arch) (CR.Atom s) (C.BVType w) ->
  CrucGen arch ids s (CR.Atom s (MM.LLVMPointerType w))
appBVAtom w app = fromBits w =<< appAtom app

addLemma :: (1 <= x, x + 1 <= y) => NatRepr x -> q y -> LeqProof 1 y
addLemma x y =
  leqProof n1 x `leqTrans`
  leqAdd (leqRefl x) n1 `leqTrans`
  leqProof (addNat x n1) y
  where
  n1 :: NatRepr 1
  n1 = knownNat


-- | Create a crucible value for a bitvector literal.
bvLit :: (1 <= w) => NatRepr w -> Integer -> CrucGen arch ids s (CR.Atom s (C.BVType w))
bvLit w i = crucibleValue (C.BVLit w (i .&. maxUnsigned w))

bitOp2 ::
  (1 <= w) =>
  NatRepr w ->
  (CR.Atom s (C.BVType w) ->
   CR.Atom s (C.BVType w) ->
   C.App (MacawExt arch) (CR.Atom s) (C.BVType w)) ->
   M.Value arch ids (M.BVType w) ->
   M.Value arch ids (M.BVType w) ->
   CrucGen arch ids s (CR.Atom s (MM.LLVMPointerType w))
bitOp2 w f x y = fromBits w =<< appAtom =<< f <$> v2c' w x <*> v2c' w y





appToCrucible :: M.App (M.Value arch ids) tp ->
                 CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
appToCrucible app = do
  archFns <- gets translateFns
  crucGenArchConstraints archFns $ do
  case app of

    M.Eq x y ->
      do xv <- v2c x
         yv <- v2c y
         case M.typeRepr x of
           M.BoolTypeRepr -> appAtom (C.BaseIsEq C.BaseBoolRepr xv yv)
           M.BVTypeRepr n ->
             do rW <- archAddrWidth
                case testEquality n rW of
                  Just Refl -> evalMacawStmt (PtrEq n xv yv)
                  Nothing ->
                    appAtom =<< C.BVEq n <$> toBits n xv <*> toBits n yv
           M.TupleTypeRepr _ -> fail "XXX: Equality on tuples not yet done."


    M.Mux tp c t f ->
      do cond <- v2c c
         tv   <- v2c t
         fv   <- v2c f
         case tp of
           M.BoolTypeRepr -> appAtom (C.BaseIte C.BaseBoolRepr cond tv fv)
           M.BVTypeRepr n ->
             do rW <- archAddrWidth
                case testEquality n rW of
                  Just Refl -> evalMacawStmt (PtrMux n cond tv fv)
                  Nothing -> appBVAtom n =<<
                                C.BVIte cond n <$> toBits n tv <*> toBits n fv
           M.TupleTypeRepr _ -> fail "XXX: Mux on tuples not yet done."


    M.TupleField tps x i ->
      undefined tps x i -- TODO: Fix this


    -- Booleans

    M.AndApp x y  -> appAtom =<< C.And     <$> v2c x <*> v2c y
    M.OrApp  x y  -> appAtom =<< C.Or      <$> v2c x <*> v2c y
    M.NotApp x    -> appAtom =<< C.Not     <$> v2c x
    M.XorApp x y  -> appAtom =<< C.BoolXor <$> v2c x <*> v2c y

    -- Extension operations
    M.Trunc x w ->
      do let wx = M.typeWidth x
         LeqProof <- return (addLemma w wx)
         appBVAtom w =<< C.BVTrunc w wx <$> v2c' wx x

    M.SExt x w ->
      do let wx = M.typeWidth x
         appBVAtom w =<< C.BVSext w wx <$> v2c' wx x

    M.UExt x w ->
      do let wx = M.typeWidth x
         appBVAtom w =<< C.BVZext w wx <$> v2c' wx x

    -- Bitvector arithmetic
    M.BVAdd w x y ->
      do xv <- v2c x
         yv <- v2c y
         aw <- archAddrWidth
         case testEquality w aw of
           Just Refl -> evalMacawStmt (PtrAdd w xv yv)
           Nothing -> appBVAtom w =<< C.BVAdd w <$> toBits w xv <*> toBits w yv

    -- Here we assume that this does not make sense for pointers.
    M.BVAdc w x y c -> do
      z <- appAtom =<< C.BVAdd w <$> v2c' w x <*> v2c' w y
      d <- appAtom =<< C.BaseIte (C.BaseBVRepr w) <$> v2c c
                                             <*> appAtom (C.BVLit w 1)
                                             <*> appAtom (C.BVLit w 0)
      appBVAtom w (C.BVAdd w z d)

    M.BVSub w x y ->
      do xv <- v2c x
         yv <- v2c y
         aw <- archAddrWidth
         case testEquality w aw of
           Just Refl -> evalMacawStmt (PtrSub w xv yv)
           Nothing -> appBVAtom w =<< C.BVSub w <$> toBits w xv <*> toBits w yv

    M.BVSbb w x y c -> do
      z <- appAtom =<< C.BVSub w <$> v2c' w x <*> v2c' w y
      d <- appAtom =<< C.BaseIte (C.BaseBVRepr w) <$> v2c c
                                             <*> appAtom (C.BVLit w 1)
                                             <*> appAtom (C.BVLit w 0)
      appBVAtom w (C.BVSub w z d)


    M.BVMul w x y -> bitOp2 w (C.BVMul w) x y

    M.BVUnsignedLe x y ->
      do let w = M.typeWidth x
         ptrW <- archAddrWidth
         xv <- v2c x
         yv <- v2c y
         case testEquality w ptrW of
           Just Refl -> evalMacawStmt (PtrLeq w xv yv)
           Nothing -> appAtom =<< C.BVUle w <$> toBits w xv <*> toBits w yv

    M.BVUnsignedLt x y ->
      do let w = M.typeWidth x
         ptrW <- archAddrWidth
         xv <- v2c x
         yv <- v2c y
         case testEquality w ptrW of
           Just Refl -> evalMacawStmt (PtrLt w xv yv)
           Nothing   -> appAtom =<< C.BVUlt w <$> toBits w xv <*> toBits w yv

    M.BVSignedLe x y ->
      do let w = M.typeWidth x
         appAtom =<< C.BVSle w <$> v2c' w x <*> v2c' w y

    M.BVSignedLt x y ->
      do let w = M.typeWidth x
         appAtom =<< C.BVSlt w <$> v2c' w x <*> v2c' w y

    -- Bitwise operations
    M.BVTestBit x i -> do
      let w = M.typeWidth x
      one <- bvLit w 1
      -- Create mask for ith index
      i_mask <- appAtom =<< C.BVShl w one <$> (toBits w =<< v2c i)
      -- Mask off index
      x_mask <- appAtom =<< C.BVAnd w <$> (toBits w =<< v2c x) <*> pure i_mask
      -- Check to see if result is i_mask
      appAtom (C.BVEq w x_mask i_mask)

    M.BVComplement w x -> appBVAtom w =<< C.BVNot w <$> v2c' w x

    M.BVAnd w x y -> bitOp2 w (C.BVAnd  w) x y
    M.BVOr  w x y -> bitOp2 w (C.BVOr   w) x y
    M.BVXor w x y -> bitOp2 w (C.BVXor  w) x y
    M.BVShl w x y -> bitOp2 w (C.BVShl  w) x y
    M.BVShr w x y -> bitOp2 w (C.BVLshr w) x y
    M.BVSar w x y -> bitOp2 w (C.BVAshr w) x y

    M.UadcOverflows x y c -> do
      let w = M.typeWidth x
      r <- MacawOverflows Uadc w <$> v2c' w x <*> v2c' w y <*> v2c c
      evalMacawExt r
    M.SadcOverflows x y c -> do
      let w = M.typeWidth x
      r <- MacawOverflows Sadc w <$> v2c' w x <*> v2c' w y <*> v2c c
      evalMacawExt r
    M.UsbbOverflows x y b -> do
      let w = M.typeWidth x
      r <- MacawOverflows Usbb w <$> v2c' w x <*> v2c' w y <*> v2c b
      evalMacawExt r
    M.SsbbOverflows x y b -> do
      let w = M.typeWidth x
      r <- MacawOverflows Ssbb w <$> v2c' w x <*> v2c' w y <*> v2c b
      evalMacawExt r
    M.PopCount w x -> do
      undefined w x
    M.ReverseBytes w x -> do
      undefined w x
    M.Bsf w x -> do
      undefined w x
    M.Bsr w x -> do
      undefined w x



valueToCrucible :: M.Value arch ids tp
                -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
valueToCrucible v = do
 archFns <- gets translateFns
 crucGenArchConstraints archFns $ do
 case v of
    M.BVValue w c -> fromBits w =<< bvLit w c
    M.BoolValue b -> crucibleValue (C.BoolLit b)

    M.RelocatableValue w addr ->
      do rW <- archAddrWidth
         case testEquality w rW of
           Just Refl
            | M.addrBase addr == 0 && M.addrOffset addr == 0 ->
              evalMacawExt (MacawNullPtr w)
            | otherwise -> evalMacawStmt (MacawGlobalPtr addr)
           Nothing ->
             fail $ unlines [ "Unexpected relocatable value width"
                            , "*** Expected: " ++ show rW
                            , "*** Width:    " ++ show w
                            , "*** Base:     " ++ show (M.addrBase addr)
                            , "*** Offset:   " ++ show (M.addrOffset addr)
                            ]

    M.Initial r ->
      getRegValue r

    M.AssignedValue asgn -> do
      let idx = M.assignId asgn
      amap <- use $ crucPStateLens . assignValueMapLens
      case MapF.lookup idx amap of
        Just (MacawCrucibleValue r) -> pure r
        Nothing ->  fail "internal: Assignment id is not bound."

-- | Create a fresh symbolic value of the given type.
freshSymbolic :: M.TypeRepr tp
              -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
freshSymbolic repr = evalMacawStmt (MacawFreshSymbolic repr)

evalMacawStmt :: MacawStmtExtension arch (CR.Atom s) tp ->
                  CrucGen arch ids s (CR.Atom s tp)
evalMacawStmt = evalAtom . CR.EvalExt

evalArchStmt :: MacawArchStmtExtension arch (CR.Atom s) tp -> CrucGen arch ids s (CR.Atom s tp)
evalArchStmt = evalMacawStmt . MacawArchStmtExtension

assignRhsToCrucible :: M.AssignRhs arch (M.Value arch ids) tp
                    -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
assignRhsToCrucible rhs =
 gets translateFns >>= \archFns ->
 crucGenArchConstraints archFns $
  case rhs of
    M.EvalApp app -> appToCrucible app
    M.SetUndefined mrepr -> freshSymbolic mrepr
    M.ReadMem addr repr -> do
      caddr <- valueToCrucible addr
      w     <- archAddrWidth
      evalMacawStmt (MacawReadMem w repr caddr)
    M.CondReadMem repr cond addr def -> do
      ccond <- valueToCrucible cond
      caddr <- valueToCrucible addr
      cdef  <- valueToCrucible def
      w     <- archAddrWidth
      evalMacawStmt (MacawCondReadMem w repr ccond caddr cdef)
    M.EvalArchFn f _ -> do
      fns <- translateFns <$> get
      crucGenArchFn fns f

addMacawStmt :: M.Stmt arch ids -> CrucGen arch ids s ()
addMacawStmt stmt =
  gets translateFns >>= \archFns ->
  crucGenArchConstraints archFns $
  case stmt of
    M.AssignStmt asgn -> do
      let idx = M.assignId asgn
      a <- assignRhsToCrucible (M.assignRhs asgn)
      crucPStateLens . assignValueMapLens %= MapF.insert idx (MacawCrucibleValue a)
    M.WriteMem addr repr val -> do
      caddr <- valueToCrucible addr
      cval  <- valueToCrucible val
      w     <- archAddrWidth
      void $ evalMacawStmt (MacawWriteMem w repr caddr cval)
    M.PlaceHolderStmt _vals msg -> do
      cmsg <- crucibleValue (C.TextLit (Text.pack msg))
      addTermStmt (CR.ErrorStmt cmsg)
    M.InstructionStart off _ -> do
      -- Update the position
      modify $ \s -> s { codeOff = off }
    M.Comment _txt -> do
      pure ()
    M.ExecArchStmt astmt -> do
      fns <- translateFns <$> get
      crucGenArchStmt fns astmt

lookupCrucibleLabel :: Map Word64 (CR.Label s)
                       -- ^ Map from block index to Crucible label
                    -> Word64
                       -- ^ Index of crucible block
                    -> CrucGen arch ids s (CR.Label s)
lookupCrucibleLabel m idx = do
  case Map.lookup idx m of
    Nothing -> fail $ "Could not find label for block " ++ show idx
    Just l -> pure l

-- | Create a crucible struct for registers from a register state.
createRegStruct :: forall arch ids s
                .  M.RegState (M.ArchReg arch) (M.Value arch ids)
                -> CrucGen arch ids s (CR.Atom s (ArchRegStruct arch))
createRegStruct regs = do
  archFns <- gets translateFns
  crucGenArchConstraints archFns $ do
  let regAssign = crucGenRegAssignment archFns
  let tps = fmapFC M.typeRepr regAssign
  let a = fmapFC (\r -> regs ^. M.boundValue r) regAssign
  fields <- macawAssignToCrucM valueToCrucible a
  crucibleValue $ C.MkStruct (typeCtxToCrucible tps) fields

addMacawTermStmt :: Map Word64 (CR.Label s)
                    -- ^ Map from block index to Crucible label
                 -> M.TermStmt arch ids
                 -> CrucGen arch ids s ()
addMacawTermStmt blockLabelMap tstmt =
  case tstmt of
    M.FetchAndExecute regs -> do
      s <- createRegStruct regs
      addTermStmt (CR.Return s)
    M.Branch macawPred macawTrueLbl macawFalseLbl -> do
      p <- valueToCrucible macawPred
      t <- lookupCrucibleLabel blockLabelMap macawTrueLbl
      f <- lookupCrucibleLabel blockLabelMap macawFalseLbl
      addTermStmt (CR.Br p t f)
    M.ArchTermStmt ts regs -> do
      fns <- translateFns <$> get
      crucGenArchTermStmt fns ts regs
    M.TranslateError _regs msg -> do
      cmsg <- crucibleValue (C.TextLit msg)
      addTermStmt (CR.ErrorStmt cmsg)

-----------------

-- | Monad for adding new blocks to a state.
newtype MacawMonad arch ids s a
  = MacawMonad ( ExceptT String (StateT (CrucPersistentState ids s) (ST s)) a)
  deriving ( Functor
           , Applicative
           , Monad
           , MonadError String
           , MonadState (CrucPersistentState ids s)
           )

runMacawMonad :: CrucPersistentState ids s
              -> MacawMonad arch ids s a
              -> ST s (Either String a, CrucPersistentState ids s)
runMacawMonad s (MacawMonad m) = runStateT (runExceptT m) s

mmExecST :: ST s a -> MacawMonad arch ids s a
mmExecST = MacawMonad . lift . lift

runCrucGen :: forall arch ids s
           .  MacawSymbolicArchFunctions arch
           -> MemSegmentMap (M.ArchAddrWidth arch)
              -- ^ Base address map
           -> (M.ArchAddrWord arch -> C.Position)
              -- ^ Function for generating position from offset from start of this block.
           -> M.ArchAddrWord arch
              -- ^ Offset of this code relative to start of block
           -> CR.Label s
              -- ^ Label for this block
           -> CR.Reg s (ArchRegStruct arch)
              -- ^ Crucible register for struct containing all Macaw registers.
           -> CrucGen arch ids s ()
           -> MacawMonad arch ids s (CR.Block (MacawExt arch) s (MacawFunctionResult arch), M.ArchAddrWord arch)
runCrucGen archFns baseAddrMap posFn off lbl regReg action = crucGenArchConstraints archFns $ do
  ps <- get
  let regAssign = crucGenRegAssignment archFns
  let crucRegTypes = crucArchRegTypes archFns
  let s0 = CrucGenState { translateFns = archFns
                        , crucMemBaseAddrMap = baseAddrMap
                        , crucRegIndexMap = mkRegIndexMap regAssign (Ctx.size crucRegTypes)
                        , crucPState = ps
                        , crucRegisterReg = regReg
                        , macawPositionFn = posFn
                        , blockLabel = lbl
                        , codeOff    = off
                        , prevStmts  = []
                        }
  let cont _s () = fail "Unterminated crucible block"
  (s, tstmt)  <- mmExecST $ unCrucGen action s0 cont
  put (crucPState s)
  let termPos = posFn (codeOff s)
  let stmts = Seq.fromList (reverse (prevStmts s))
  let term = C.Posd termPos tstmt
  let blk = CR.mkBlock (CR.LabelID lbl) Set.empty stmts term
  pure (blk, codeOff s)

addMacawBlock :: M.MemWidth (M.ArchAddrWidth arch)
              => MacawSymbolicArchFunctions arch
              -> MemSegmentMap (M.ArchAddrWidth arch)
              -- ^ Base address map
              -> Map Word64 (CR.Label s)
                 -- ^ Map from block index to Crucible label
              -> (M.ArchAddrWord arch -> C.Position)
                 -- ^ Function for generating position from offset from start of this block.
              -> M.Block arch ids
              -> MacawMonad arch ids s (CR.Block (MacawExt arch) s (MacawFunctionResult arch))
addMacawBlock archFns baseAddrMap blockLabelMap posFn b = do
  let idx = M.blockLabel b
  lbl <-
    case Map.lookup idx blockLabelMap of
      Just lbl ->
        pure lbl
      Nothing ->
        throwError $ "Internal: Could not find block with index " ++ show idx
  let archRegStructRepr = C.StructRepr (crucArchRegTypes archFns)
  let regReg = CR.Reg { CR.regPosition = posFn 0
                      , CR.regId = 0
                      , CR.typeOfReg = archRegStructRepr
                      }
  let regStruct = CR.Atom { CR.atomPosition = C.InternalPos
                          , CR.atomId = 0
                          , CR.atomSource = CR.FnInput
                          , CR.typeOfAtom = archRegStructRepr
                          }
  fmap fst $ runCrucGen archFns baseAddrMap posFn 0 lbl regReg $ do
    addStmt $ CR.SetReg regReg regStruct
    mapM_ addMacawStmt (M.blockStmts b)
    addMacawTermStmt blockLabelMap (M.blockTerm b)

parsedBlockLabel :: (Ord addr, Show addr)
                 => Map (addr, Word64) (CR.Label s)
                    -- ^ Map from block addresses to starting label
                 -> addr
                 -> Word64
                 -> CR.Label s
parsedBlockLabel blockLabelMap addr idx =
  fromMaybe (error $ "Could not find entry point: " ++ show addr) $
  Map.lookup (addr, idx) blockLabelMap

setMachineRegs :: CR.Atom s (ArchRegStruct arch) -> CrucGen arch ids s ()
setMachineRegs newRegs = do
  regReg <- gets crucRegisterReg
  addStmt $ CR.SetReg regReg newRegs

-- | Map from block information to Crucible label (used to generate term statements)
type BlockLabelMap arch s = Map (M.ArchSegmentOff arch, Word64) (CR.Label s)

addMacawParsedTermStmt :: BlockLabelMap arch s
                          -- ^ Block label map for this function
                       -> M.ArchSegmentOff arch
                          -- ^ Address of this block
                       -> M.ParsedTermStmt arch ids
                       -> CrucGen arch ids s ()
addMacawParsedTermStmt blockLabelMap thisAddr tstmt = do
 archFns <- translateFns <$> get
 crucGenArchConstraints archFns $ do
  case tstmt of
    M.ParsedCall regs mret -> do
      curRegs <- createRegStruct regs
      newRegs <- evalMacawStmt (MacawCall (crucArchRegTypes archFns) curRegs)
      case mret of
        Just nextAddr -> do
          setMachineRegs newRegs
          addTermStmt $ CR.Jump (parsedBlockLabel blockLabelMap nextAddr 0)
        Nothing ->
          addTermStmt $ CR.Return newRegs
    M.ParsedJump regs nextAddr -> do
      setMachineRegs =<< createRegStruct regs
      addTermStmt $ CR.Jump (parsedBlockLabel blockLabelMap nextAddr 0)
    M.ParsedLookupTable regs _idx _possibleAddrs -> do
      setMachineRegs =<< createRegStruct regs
      let cond = undefined
      -- TODO: Add ability in CrucGen to generate new labels and add new blocks.
      let tlbl = undefined
      let flbl = undefined
      addTermStmt $! CR.Br cond tlbl flbl
    M.ParsedReturn regs -> do
      regValues <- createRegStruct regs
      addTermStmt $ CR.Return regValues
    M.ParsedIte c t f -> do
      crucCond <- valueToCrucible c
      let tlbl = parsedBlockLabel blockLabelMap thisAddr (M.stmtsIdent t)
      let flbl = parsedBlockLabel blockLabelMap thisAddr (M.stmtsIdent f)
      addTermStmt $! CR.Br crucCond tlbl flbl
    M.ParsedArchTermStmt aterm regs _mret -> do
      crucGenArchTermStmt archFns aterm regs
    M.ParsedTranslateError msg -> do
      msgVal <- crucibleValue (C.TextLit msg)
      addTermStmt $ CR.ErrorStmt msgVal
    M.ClassifyFailure _regs -> do
      msgVal <- crucibleValue $ C.TextLit $ Text.pack $ "Could not identify block at " ++ show thisAddr
      addTermStmt $ CR.ErrorStmt msgVal

nextStatements :: M.ParsedTermStmt arch ids -> [M.StatementList arch ids]
nextStatements tstmt =
  case tstmt of
    M.ParsedIte _ x y -> [x, y]
    _ -> []

addStatementList :: MacawSymbolicArchFunctions arch
                 -> MemSegmentMap (M.ArchAddrWidth arch)
                 -- ^ Base address map
                 -> BlockLabelMap arch s
                 -- ^ Map from block index to Crucible label
                 -> M.ArchSegmentOff arch
                 -- ^ Address of block that starts statements
                 -> (M.ArchAddrWord arch -> C.Position)
                    -- ^ Function for generating position from offset from start of this block.
                 -> CR.Reg s (ArchRegStruct arch)
                    -- ^ Register that stores Macaw registers
                 -> [(M.ArchAddrWord arch, M.StatementList arch ids)]
                 -> [CR.Block (MacawExt arch) s (MacawFunctionResult arch)]
                 -> MacawMonad arch ids s [CR.Block (MacawExt arch) s (MacawFunctionResult arch)]
addStatementList _ _ _ _ _ _ [] rlist =
  pure (reverse rlist)
addStatementList archFns baseAddrMap blockLabelMap startAddr posFn regReg ((off,stmts):rest) r = do
  crucGenArchConstraints archFns $ do
  let idx = M.stmtsIdent stmts
  lbl <-
    case Map.lookup (startAddr, idx) blockLabelMap of
      Just lbl ->
        pure lbl
      Nothing ->
        throwError $ "Internal: Could not find block with address " ++ show startAddr ++ " index " ++ show idx
  (b,off') <-
    runCrucGen archFns baseAddrMap posFn off lbl regReg $ do
      mapM_ addMacawStmt (M.stmtsNonterm stmts)
      addMacawParsedTermStmt blockLabelMap startAddr (M.stmtsTerm stmts)
  let new = (off',) <$> nextStatements (M.stmtsTerm stmts)
  addStatementList archFns baseAddrMap blockLabelMap startAddr posFn regReg (new ++ rest) (b:r)

addParsedBlock :: forall arch ids s
               .  MacawSymbolicArchFunctions arch
               -> MemSegmentMap (M.ArchAddrWidth arch)
               -- ^ Base address map
               -> BlockLabelMap arch s
               -- ^ Map from block index to Crucible label
               -> (M.ArchSegmentOff arch -> C.Position)
               -- ^ Function for generating position from offset from start of this block.
               -> CR.Reg s (ArchRegStruct arch)
                    -- ^ Register that stores Macaw registers
               -> M.ParsedBlock arch ids
               -> MacawMonad arch ids s [CR.Block (MacawExt arch) s (MacawFunctionResult arch)]
addParsedBlock archFns memBaseVarMap blockLabelMap posFn regReg b = do
  crucGenArchConstraints archFns $ do
  let base = M.pblockAddr b
  let thisPosFn :: M.ArchAddrWord arch -> C.Position
      thisPosFn off = posFn r
        where Just r = M.incSegmentOff base (toInteger off)
  addStatementList archFns memBaseVarMap blockLabelMap
    (M.pblockAddr b) thisPosFn regReg [(0, M.blockStatementList b)] []


--------------------------------------------------------------------------------
-- Auto-generated instances

$(return [])

instance TestEqualityFC (MacawExprExtension arch) where
  testEqualityFC f =
    $(U.structuralTypeEquality [t|MacawExprExtension|]
      [ (U.DataArg 1 `U.TypeApp` U.AnyType, [|f|])
      , (U.ConType [t|NatRepr |] `U.TypeApp` U.AnyType, [|testEquality|])

      ])

instance OrdFC (MacawExprExtension arch) where
  compareFC f =
    $(U.structuralTypeOrd [t|MacawExprExtension|]
      [ (U.DataArg 1 `U.TypeApp` U.AnyType, [|f|])
      , (U.ConType [t|NatRepr|] `U.TypeApp` U.AnyType, [|compareF|])
      , (U.ConType [t|ArchNatRepr|] `U.TypeApp` U.AnyType, [|compareF|])

      ])

instance FunctorFC (MacawExprExtension arch) where
  fmapFC = fmapFCDefault

instance FoldableFC (MacawExprExtension arch) where
  foldMapFC = foldMapFCDefault

instance TraversableFC (MacawExprExtension arch) where
  traverseFC =
    $(U.structuralTraversal [t|MacawExprExtension|] [])

instance TraversableFC (MacawArchStmtExtension arch)
      => TraversableFC (MacawStmtExtension arch) where
  traverseFC =
    $(U.structuralTraversal [t|MacawStmtExtension|]
      [ (U.ConType [t|MacawArchStmtExtension|] `U.TypeApp` U.DataArg 0
                                               `U.TypeApp` U.DataArg 1
                                               `U.TypeApp` U.DataArg 2
        , [|traverseFC|])
      ]
     )
