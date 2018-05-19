{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
module Data.Macaw.PPC.Symbolic (
  ppc64MacawSymbolicFns,
  ppc64MacawEvalFn,
  ppc32MacawSymbolicFns,
  ppc32MacawEvalFn,
  F.SymFuns,
  F.newSymFuns,
  getReg,
  lookupReg,
  updateReg,
  -- * Register names
  IP,
  LNK,
  CTR,
  XER,
  CR,
  FPSCR,
  VSCR,
  GP,
  FR,
  -- * Other types
  RegContext
  ) where

import           GHC.TypeLits

import           Control.Lens ( (^.), (%~), (&) )
import           Control.Monad ( void )
import qualified Control.Monad.Catch as X
import qualified Data.Functor.Identity as I
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Parameterized.TraversableF as TF
import qualified Data.Parameterized.TraversableFC as FC
import           Data.Typeable ( Typeable )
import qualified Dismantle.PPC as D
import qualified Lang.Crucible.Backend as C
import qualified Lang.Crucible.CFG.Extension as C
import qualified Lang.Crucible.CFG.Reg as C
import qualified Lang.Crucible.Types as C
import qualified What4.Interface as C
import qualified What4.Symbol as C

import qualified Data.Macaw.CFG as MC
import qualified Data.Macaw.Types as MT
import qualified Data.Macaw.Symbolic as MS
import qualified Data.Macaw.Symbolic.PersistentState as MS
import qualified Data.Macaw.PPC as MP
import           Data.Macaw.PPC.PPCReg ( ArchWidth )

import qualified Data.Macaw.PPC.Symbolic.AtomWrapper as A
import qualified Data.Macaw.PPC.Symbolic.Functions as F
import qualified Data.Macaw.PPC.Symbolic.Repeat as R

ppc64MacawSymbolicFns :: MS.MacawSymbolicArchFunctions MP.PPC64
ppc64MacawSymbolicFns =
  MS.MacawSymbolicArchFunctions
  { MS.crucGenArchConstraints = \x -> x
  , MS.crucGenArchRegName = ppcRegName
  , MS.crucGenRegAssignment = ppcRegAssignment
  , MS.crucGenArchFn = ppcGenFn
  , MS.crucGenArchStmt = ppcGenStmt
  , MS.crucGenArchTermStmt = ppcGenTermStmt
  }

ppc32MacawSymbolicFns :: MS.MacawSymbolicArchFunctions MP.PPC32
ppc32MacawSymbolicFns =
  MS.MacawSymbolicArchFunctions
  { MS.crucGenArchConstraints = \x -> x
  , MS.crucGenArchRegName = ppcRegName
  , MS.crucGenRegAssignment = ppcRegAssignment
  , MS.crucGenArchFn = ppcGenFn
  , MS.crucGenArchStmt = ppcGenStmt
  , MS.crucGenArchTermStmt = ppcGenTermStmt
  }

type RegSize ppc = MC.RegAddrWidth (MP.PPCReg ppc)
type RegContext ppc
  =     (Ctx.EmptyCtx Ctx.::> MT.BVType (RegSize ppc)) -- IP
  C.<+> (Ctx.EmptyCtx Ctx.::> MT.BVType (RegSize ppc)) -- LNK
  C.<+> (Ctx.EmptyCtx Ctx.::> MT.BVType (RegSize ppc)) -- CTR
  C.<+> (Ctx.EmptyCtx Ctx.::> MT.BVType (RegSize ppc)) -- XER
  C.<+> (Ctx.EmptyCtx Ctx.::> MT.BVType 32)            -- CR
  C.<+> (Ctx.EmptyCtx Ctx.::> MT.BVType 32)            -- FPSCR
  C.<+> (Ctx.EmptyCtx Ctx.::> MT.BVType 32)            -- VSCR
  C.<+> R.CtxRepeat 32 (MT.BVType (RegSize ppc))       -- GPRs
  C.<+> R.CtxRepeat 64 (MT.BVType 128)                 -- VSRs

type instance MS.ArchRegContext MP.PPC64 = RegContext MP.PPC64
type instance MS.ArchRegContext MP.PPC32 = RegContext MP.PPC32

type RegAssign ppc f = Ctx.Assignment f (MS.ArchRegContext ppc)

type IP = 0
type LNK = 1
type CTR = 2
type XER = 3
type CR = 4
type FPSCR = 5
type VSCR = 6
type GP n = 7 + n
type FR n = 39 + n

getReg :: forall n t f ppc . (Ctx.Idx n (MS.ArchRegContext ppc) t) => RegAssign ppc f -> f t
getReg = (^. (Ctx.field @n))

ppc64MacawEvalFn :: (C.IsSymInterface sym)
                 => F.SymFuns MP.PPC64 sym
                 -> MS.MacawArchEvalFn sym MP.PPC64
ppc64MacawEvalFn fs = \xt s -> case xt of
  PPCPrimFn fn -> F.funcSemantics fs fn s
  PPCPrimStmt stmt -> F.stmtSemantics fs stmt s
  PPCPrimTerm term -> F.termSemantics fs term s

ppc32MacawEvalFn :: (C.IsSymInterface sym)
                 => F.SymFuns MP.PPC32 sym
                 -> MS.MacawArchEvalFn sym MP.PPC32
ppc32MacawEvalFn fs = \xt s -> case xt of
  PPCPrimFn fn -> F.funcSemantics fs fn s
  PPCPrimStmt stmt -> F.stmtSemantics fs stmt s
  PPCPrimTerm term -> F.termSemantics fs term s

ppcRegName :: MP.PPCReg ppc tp -> C.SolverSymbol
ppcRegName r = C.systemSymbol ("!" ++ show (MC.prettyF r))

ppcRegAssignment :: forall ppc
                  . (1 <= RegSize ppc)
                 => Ctx.Assignment (MP.PPCReg ppc) (RegContext ppc)
ppcRegAssignment =
  (Ctx.Empty Ctx.:> MP.PPC_IP
            Ctx.:> MP.PPC_LNK
            Ctx.:> MP.PPC_CTR
            Ctx.:> MP.PPC_XER
            Ctx.:> MP.PPC_CR
            Ctx.:> MP.PPC_FPSCR
            Ctx.:> MP.PPC_VSCR)
  Ctx.<++> (R.repeatAssign (MP.PPC_GP . D.GPR . fromIntegral) :: Ctx.Assignment (MP.PPCReg ppc) (R.CtxRepeat 32 (MT.BVType (RegSize ppc))))
  Ctx.<++> (R.repeatAssign (MP.PPC_FR . D.VSReg . fromIntegral) :: Ctx.Assignment (MP.PPCReg ppc) (R.CtxRepeat 64 (MT.BVType 128)))

data PPCSymbolicException ppc = MissingRegisterInState (Some (MP.PPCReg ppc))

deriving instance (Typeable ppc) => Show (PPCSymbolicException ppc)

instance (Typeable ppc) => X.Exception (PPCSymbolicException ppc)

regIndexMap :: forall ppc
             . (1 <= RegSize ppc, 1 <= MC.ArchAddrWidth ppc,
                MS.ArchRegContext ppc ~ RegContext ppc,
                MC.ArchReg ppc ~ MP.PPCReg ppc,
                ArchWidth ppc)
            => MS.RegIndexMap ppc
regIndexMap = MS.mkRegIndexMap assgn sz
  where
    assgn = ppcRegAssignment @ppc
    sz = Ctx.size (MS.typeCtxToCrucible (FC.fmapFC MT.typeRepr assgn))

lookupReg :: (1 <= RegSize ppc, 1 <= MC.ArchAddrWidth ppc,
              X.MonadThrow m,
              Typeable ppc,
              MS.ArchRegContext ppc ~ RegContext ppc,
              MC.ArchReg ppc ~ MP.PPCReg ppc,
              ArchWidth ppc)
          => MP.PPCReg ppc tp
          -> Ctx.Assignment f (MS.MacawCrucibleRegTypes ppc)
          -> m (f (MS.ToCrucibleType tp))
lookupReg r asgn =
  case MapF.lookup r regIndexMap of
    Nothing -> X.throwM (MissingRegisterInState (Some r))
    Just pair -> return (asgn Ctx.! MS.crucibleIndex pair)

updateReg :: (1 <= RegSize ppc, 1 <= MC.ArchAddrWidth ppc,
                MS.ArchRegContext ppc ~ RegContext ppc,
                MC.ArchReg ppc ~ MP.PPCReg ppc,
                Typeable ppc,
                X.MonadThrow m,
                ArchWidth ppc)
          => MP.PPCReg ppc tp
          -> (f (MS.ToCrucibleType tp) -> f (MS.ToCrucibleType tp))
          -> Ctx.Assignment f (MS.MacawCrucibleRegTypes ppc)
          -> m (Ctx.Assignment f (MS.MacawCrucibleRegTypes ppc))
updateReg r upd asgn = do
  case MapF.lookup r regIndexMap of
    Nothing -> X.throwM (MissingRegisterInState (Some r))
    Just pair -> return (asgn & MapF.ixF (MS.crucibleIndex pair) %~ upd)

ppcGenFn :: forall ids s tp ppc
          . (MS.MacawArchStmtExtension ppc ~ PPCStmtExtension ppc)
         => MP.PPCPrimFn ppc (MC.Value ppc ids) tp
         -> MS.CrucGen ppc ids s (C.Atom s (MS.ToCrucibleType tp))
ppcGenFn fn = do
  let f :: MC.Value ppc ids a -> MS.CrucGen ppc ids s (A.AtomWrapper (C.Atom s) a)
      f x = A.AtomWrapper <$> MS.valueToCrucible x
  r <- FC.traverseFC f fn
  MS.evalArchStmt (PPCPrimFn r)

ppcGenStmt :: forall ppc ids s
            . (MS.MacawArchStmtExtension ppc ~ PPCStmtExtension ppc)
           => MP.PPCStmt ppc (MC.Value ppc ids)
           -> MS.CrucGen ppc ids s ()
ppcGenStmt s = do
  let f :: MC.Value ppc ids a -> MS.CrucGen ppc ids s (A.AtomWrapper (C.Atom s) a)
      f x = A.AtomWrapper <$> MS.valueToCrucible x
  s' <- TF.traverseF f s
  void (MS.evalArchStmt (PPCPrimStmt s'))

ppcGenTermStmt :: forall ppc ids s
                . (MS.MacawArchStmtExtension ppc ~ PPCStmtExtension ppc)
               => MP.PPCTermStmt ids
               -> MC.RegState (MP.PPCReg ppc) (MC.Value ppc ids)
               -> MS.CrucGen ppc ids s ()
ppcGenTermStmt ts _rs =
  void (MS.evalArchStmt (PPCPrimTerm ts))

data PPCStmtExtension ppc (f :: C.CrucibleType -> *) (ctp :: C.CrucibleType) where
  -- | Wrappers around the arch-specific functions in PowerPC; these are
  -- interpreted in 'funcSemantics'.
  PPCPrimFn :: MP.PPCPrimFn ppc (A.AtomWrapper f) t
            -> PPCStmtExtension ppc f (MS.ToCrucibleType t)
  -- | Wrappers around the arch-specific statements in PowerPC; these are
  -- interpreted in 'stmtSemantics'
  PPCPrimStmt :: MP.PPCStmt ppc (A.AtomWrapper f)
              -> PPCStmtExtension ppc f C.UnitType
  -- | Wrappers around the arch-specific terminators in PowerPC; these are
  -- interpreted in 'termSemantics'
  PPCPrimTerm :: MP.PPCTermStmt ids -> PPCStmtExtension ppc f C.UnitType

instance FC.FunctorFC (PPCStmtExtension ppc) where
  fmapFC f (PPCPrimFn x) = PPCPrimFn (FC.fmapFC (A.liftAtomMap f) x)
  fmapFC f (PPCPrimStmt s) = PPCPrimStmt (TF.fmapF (A.liftAtomMap f) s)
  fmapFC _f (PPCPrimTerm t) = PPCPrimTerm t

instance FC.FoldableFC (PPCStmtExtension ppc) where
  foldMapFC f (PPCPrimFn x) = FC.foldMapFC (A.liftAtomIn f) x
  foldMapFC f (PPCPrimStmt s) = TF.foldMapF (A.liftAtomIn f) s
  -- There are no contents in any of the terminator statements for now, so there
  -- is no traversal here
  foldMapFC _f (PPCPrimTerm _t) = mempty

instance FC.TraversableFC (PPCStmtExtension ppc) where
  traverseFC f (PPCPrimFn x) = PPCPrimFn <$> FC.traverseFC (A.liftAtomTrav f) x
  traverseFC f (PPCPrimStmt s) = PPCPrimStmt <$> TF.traverseF (A.liftAtomTrav f) s
  traverseFC _f (PPCPrimTerm t) = pure (PPCPrimTerm t)

instance (1 <= MC.RegAddrWidth (MC.ArchReg ppc)) => C.TypeApp (PPCStmtExtension ppc) where
  appType (PPCPrimFn x) = MS.typeToCrucible (MT.typeRepr x)
  appType (PPCPrimStmt _s) = C.UnitRepr
  appType (PPCPrimTerm _t) = C.UnitRepr

instance C.PrettyApp (PPCStmtExtension ppc) where
  ppApp ppSub (PPCPrimFn x) =
    I.runIdentity (MC.ppArchFn (I.Identity . A.liftAtomIn ppSub) x)
  ppApp ppSub (PPCPrimStmt s) =
    MC.ppArchStmt (A.liftAtomIn ppSub) s
  ppApp _ppSub (PPCPrimTerm t) = MC.prettyF t

type instance MS.MacawArchStmtExtension MP.PPC64 = PPCStmtExtension MP.PPC64
type instance MS.MacawArchStmtExtension MP.PPC32 = PPCStmtExtension MP.PPC32

