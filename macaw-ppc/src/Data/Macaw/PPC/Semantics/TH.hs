{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeApplications #-}

module Data.Macaw.PPC.Semantics.TH
  ( genExecInstruction
  ) where

import qualified Data.ByteString as BS
import qualified Data.Constraint as C

import Control.Lens
import Data.Proxy
import Language.Haskell.TH
import GHC.TypeLits

import           Data.Parameterized.Classes
import qualified Data.Parameterized.Map as Map
import qualified Data.Parameterized.Nonce as PN
import           Data.Parameterized.Some ( Some(..) )
import           Data.Parameterized.Witness ( Witness(..) )
import qualified Lang.Crucible.Solver.SimpleBuilder as S
import qualified Lang.Crucible.Solver.SimpleBackend as S
import qualified Lang.Crucible.BaseTypes as S

import qualified Dismantle.PPC as D
import           SemMC.Formula
import qualified SemMC.Architecture as A
import qualified SemMC.Architecture.PPC.Location as APPC
import qualified Data.Macaw.CFG as M
import qualified Data.Macaw.Types as M

import Data.Parameterized.NatRepr (knownNat)

import Data.Macaw.PPC.Generator
import Data.Macaw.PPC.PPCReg

-- generate a different case for each key/value pair in the map
genExecInstruction :: (A.Architecture arch, OrdF a, ShowF a)
                   => proxy arch
                   -> (forall sh . c sh C.:- BuildOperandList arch sh)
                   -> [(Some (Witness c a), BS.ByteString)]
                   -> Q Exp
genExecInstruction _ impl semantics = do
  Some ng <- runIO PN.newIONonceGenerator
  _sym <- runIO (S.newSimpleBackend ng)
  -- formulas <- runIO (loadFormulas sym impl semantics)
  [| undefined |]

-- SemMC.Formula: instantiateFormula

type Sym t = S.SimpleBackend t

type family FromCrucibleBaseType (btp :: S.BaseType) :: M.Type where
  FromCrucibleBaseType (S.BaseBVType w) = M.BVType w
  FromCrucibleBaseType (S.BaseBoolType) = M.BoolType

-- Unimplemented:

-- Don't need to implement:
--   - all SemiRing operations (not using)
--   - all "Basic arithmetic operations" (not using)
--   - all "Operations that introduce irrational numbers" (not using)
--   - BVUnaryTerm (not using)
--   - all array operations (probably not using)
--   - all conversions
--   - all complex operations
--   - all structs

-- Can implement now:
--   - BVConcat (shifts, extensions and adds?)
--   - BVSelect
--   - BVNeg (complement, add 1)

-- Might need to implement later:
--   - BVUdiv, BVUrem, BVSdiv, BVSrem

crucAppToExpr :: S.App (S.Elt t) ctp -> Expr ppc ids (FromCrucibleBaseType ctp)
crucAppToExpr S.TrueBool  = ValueExpr (M.BoolValue True)
crucAppToExpr S.FalseBool = ValueExpr (M.BoolValue False)
crucAppToExpr (S.NotBool bool) = AppExpr $ M.NotApp (eltToExpr bool)
-- crucAppToExpr (S.AndBool bool1 bool2)
--   = AppExpr $ M.AndApp (eltToExpr bool1) (eltToExpr bool2)
-- crucAppToExpr (S.XorBool bool1 bool2)
--   = AppExpr $ M.XorApp (eltToExpr bool1) (eltToExpr bool2)
-- crucAppToExpr (S.IteBool test t f)
--   = AppExpr $ M.Mux M.BoolTypeRepr (eltToExpr test) (eltToExpr t) (eltToExpr f)
-- crucAppToExpr (S.BVIte w numBranches test t f) -- what is numBranches for?
--   = AppExpr $ M.Mux (M.BVTypeRepr w) (eltToExpr test) (eltToExpr t) (eltToExpr f)
-- crucAppToExpr (S.BVTestBit ix bv)
--   = AppExpr $ undefined
-- crucAppToExpr (S.BVEq bv1 bv2) = AppExpr $ M.Eq (eltToExpr bv1) (eltToExpr bv2)
-- crucAppToExpr (S.BVSlt bv1 bv2)
--   = AppExpr $ M.BVSignedLt (eltToExpr bv1) (eltToExpr bv2)
-- crucAppToExpr (S.BVUlt bv1 bv2)
--   = AppExpr $ M.BVUnsignedLt (eltToExpr bv1) (eltToExpr bv2)
-- crucAppToExpr (S.BVAdd repr bv1 bv2)
--   = AppExpr $ M.BVAdd repr (eltToExpr bv1) (eltToExpr bv2)
-- crucAppToExpr (S.BVMul repr bv1 bv2)
--   = AppExpr $ M.BVMul repr (eltToExpr bv1) (eltToExpr bv2)
-- crucAppToExpr (S.BVShl repr bv1 bv2)
--   = AppExpr $ M.BVShl repr (eltToExpr bv1) (eltToExpr bv2)
-- crucAppToExpr (S.BVLshr repr bv1 bv2)
--   = AppExpr $ M.BVShr repr (eltToExpr bv1) (eltToExpr bv2)
-- crucAppToExpr (S.BVAshr repr bv1 bv2)
--   = AppExpr $ M.BVSar repr (eltToExpr bv1) (eltToExpr bv2)
-- crucAppToExpr (S.BVZext repr bv)
--   = AppExpr $ M.UExt (eltToExpr bv) repr
-- crucAppToExpr (S.BVSext repr bv)
--   = AppExpr $ M.SExt (eltToExpr bv) repr
-- crucAppToExpr (S.BVTrunc repr bv)
--   = AppExpr $ M.Trunc (eltToExpr bv) repr
-- crucAppToExpr (S.BVBitNot repr bv)
--   = AppExpr $ M.BVComplement repr (eltToExpr bv)
-- crucAppToExpr (S.BVBitAnd repr bv1 bv2)
--   = AppExpr $ M.BVAnd repr (eltToExpr bv1) (eltToExpr bv2)
-- crucAppToExpr (S.BVBitOr repr bv1 bv2)
--   = AppExpr $ M.BVOr repr (eltToExpr bv1) (eltToExpr bv2)
-- crucAppToExpr (S.BVBitXor repr bv1 bv2)
--   = AppExpr $ M.BVXor repr (eltToExpr bv1) (eltToExpr bv2)
-- crucAppToExpr _ = error "crucAppToExpr: unimplemented crucible operation"

eltToExpr :: S.Elt t ctp -> Expr ppc ids (FromCrucibleBaseType ctp)
eltToExpr (S.BVElt w val loc) = ValueExpr (M.BVValue w val)
eltToExpr (S.AppElt appElt) = crucAppToExpr (S.appEltApp appElt)

locToReg :: (1 <= APPC.ArchRegWidth ppc, M.RegAddrWidth (PPCReg ppc) ~ APPC.ArchRegWidth ppc) =>
            proxy ppc -> APPC.Location ppc ctp -> PPCReg ppc (FromCrucibleBaseType ctp)
locToReg _ (APPC.LocGPR gpr) = PPC_GP gpr
-- fill the rest out later

-- | Given a location to modify and a crucible formula, construct a PPCGenerator that
-- will modify the location by the function encoded in the formula.
interpretFormula :: forall tp ppc t ctp s .
                    (1 <= APPC.ArchRegWidth ppc,
                     M.RegAddrWidth (PPCReg ppc) ~ APPC.ArchRegWidth ppc)
                 => APPC.Location ppc ctp
                 -> S.Elt t ctp
                 -> PPCGenerator ppc s ()
interpretFormula loc elt = do
  let expr = eltToExpr elt
  let reg  = (locToReg (Proxy @ppc) loc)
  case expr of
    ValueExpr val -> curPPCState . M.boundValue reg .= val
    AppExpr app -> do
      assignment <- addAssignment (M.EvalApp app)
      curPPCState . M.boundValue reg .= M.AssignedValue assignment
