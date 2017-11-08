-- This module is currently unused; it models certain functions we are generating via
-- template haskell, but these functions aren't actually used themselves.

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeApplications #-}

module Data.Macaw.PPC.Semantics.Base
  ( crucAppToExpr
  , locToReg
  , interpretFormula
  ) where

import           Data.Proxy
import           GHC.TypeLits

import           Data.Parameterized.Classes
import qualified Lang.Crucible.Solver.SimpleBuilder as S
import qualified Lang.Crucible.BaseTypes as S

import qualified SemMC.Architecture.PPC.Location as APPC
import qualified Data.Macaw.CFG as M
import qualified Data.Macaw.Types as M

import Data.Parameterized.NatRepr ( knownNat
                                  , addNat
                                  , natValue
                                  )

import           Data.Macaw.PPC.Generator
import           Data.Macaw.PPC.PPCReg
import           Data.Macaw.PPC.Semantics.TH

crucAppToExpr :: (M.ArchConstraints ppc) => S.App (S.Elt t) ctp -> PPCGenerator ppc ids s (Expr ppc ids (FromCrucibleBaseType ctp))
crucAppToExpr S.TrueBool  = return $ ValueExpr (M.BoolValue True)
crucAppToExpr S.FalseBool = return $ ValueExpr (M.BoolValue False)
crucAppToExpr (S.NotBool bool) = (AppExpr . M.NotApp) <$> addElt bool
crucAppToExpr (S.AndBool bool1 bool2) = AppExpr <$> do
  M.AndApp <$> addElt bool1 <*> addElt bool2
crucAppToExpr (S.XorBool bool1 bool2) = AppExpr <$> do
  M.XorApp <$> addElt bool1 <*> addElt bool2
crucAppToExpr (S.IteBool test t f) = AppExpr <$> do
  M.Mux <$> pure M.BoolTypeRepr <*> addElt test <*> addElt t <*> addElt f
crucAppToExpr (S.BVIte w _ test t f) = AppExpr <$> do -- what is _ for?
  M.Mux <$> pure (M.BVTypeRepr w) <*> addElt test <*> addElt t <*> addElt f
crucAppToExpr (S.BVEq bv1 bv2) = AppExpr <$> do
  M.Eq <$> addElt bv1 <*> addElt bv2
crucAppToExpr (S.BVSlt bv1 bv2) = AppExpr <$> do
  M.BVSignedLt <$> addElt bv1 <*> addElt bv2
crucAppToExpr (S.BVUlt bv1 bv2) = AppExpr <$> do
  M.BVUnsignedLt <$> addElt bv1 <*> addElt bv2
crucAppToExpr (S.BVConcat w bv1 bv2) = AppExpr <$> do
  let u = S.bvWidth bv1
      v = S.bvWidth bv2
  bv1Val <- addElt bv1
  bv2Val <- addElt bv2
  S.LeqProof <- return $ S.leqAdd2 (S.leqRefl u) (S.leqProof (knownNat @1) v)
  pf1@S.LeqProof <- return $ S.leqAdd2 (S.leqRefl v) (S.leqProof (knownNat @1) u)
  Refl <- return $ S.plusComm u v
  S.LeqProof <- return $ S.leqTrans pf1 (S.leqRefl w)
  bv1Ext <- addExpr (AppExpr (M.UExt bv1Val w)) ---(u `addNat` v)))
  bv2Ext <- addExpr (AppExpr (M.UExt bv2Val w))
  bv1Shifter <- addExpr (ValueExpr (M.BVValue w (natValue v)))
  bv1Shf <- addExpr (AppExpr (M.BVShl w bv1Ext bv1Shifter))
  return $ M.BVOr w bv1Shf bv2Ext
crucAppToExpr (S.BVSelect idx n bv) = do
  let w = S.bvWidth bv
  bvVal <- addElt bv
  case natValue n + 1 <= natValue w of
    True -> do
      -- Is there a way to just "know" that n + 1 <= w?
      Just S.LeqProof <- return $ S.testLeq (n `addNat` (knownNat @1)) w
      pf1@S.LeqProof <- return $ S.leqAdd2 (S.leqRefl idx) (S.leqProof (knownNat @1) n)
      pf2@S.LeqProof <- return $ S.leqAdd (S.leqRefl (knownNat @1)) idx
      Refl <- return $ S.plusComm (knownNat @1) idx
      pf3@S.LeqProof <- return $ S.leqTrans pf2 pf1
      S.LeqProof <- return $ S.leqTrans pf3 (S.leqProof (idx `addNat` n) w)
      bvShf <- addExpr (AppExpr (M.BVShr w bvVal (M.mkLit w (natValue idx))))
      return $ AppExpr (M.Trunc bvShf n)
    False -> do
      -- Is there a way to just "know" that n = w?
      Just Refl <- return $ testEquality n w
      return $ ValueExpr bvVal
crucAppToExpr (S.BVNeg w bv) = do
  bvVal  <- addElt bv
  bvComp <- addExpr (AppExpr (M.BVComplement w bvVal))
  return $ AppExpr (M.BVAdd w bvComp (M.mkLit w 1))
crucAppToExpr (S.BVTestBit idx bv) = AppExpr <$> do
  M.BVTestBit
    <$> addExpr (ValueExpr (M.BVValue (S.bvWidth bv) (fromIntegral idx)))
    <*> addElt bv
crucAppToExpr (S.BVAdd repr bv1 bv2) = AppExpr <$> do
  M.BVAdd <$> pure repr <*> addElt bv1 <*> addElt bv2
crucAppToExpr (S.BVMul repr bv1 bv2) = AppExpr <$> do
  M.BVMul <$> pure repr <*> addElt bv1 <*> addElt bv2
crucAppToExpr (S.BVShl repr bv1 bv2) = AppExpr <$> do
  M.BVShl <$> pure repr <*> addElt bv1 <*> addElt bv2
crucAppToExpr (S.BVLshr repr bv1 bv2) = AppExpr <$> do
  M.BVShr <$> pure repr <*> addElt bv1 <*> addElt bv2
crucAppToExpr (S.BVAshr repr bv1 bv2) = AppExpr <$> do
  M.BVSar <$> pure repr <*> addElt bv1 <*> addElt bv2
crucAppToExpr (S.BVZext repr bv) = AppExpr <$> do
  M.UExt <$> addElt bv <*> pure repr
crucAppToExpr (S.BVSext repr bv) = AppExpr <$> do
  M.SExt <$> addElt bv <*> pure repr
crucAppToExpr (S.BVTrunc repr bv) = AppExpr <$> do
  M.Trunc <$> addElt bv <*> pure repr
crucAppToExpr (S.BVBitNot repr bv) = AppExpr <$> do
  M.BVComplement <$> pure repr <*> addElt bv
crucAppToExpr (S.BVBitAnd repr bv1 bv2) = AppExpr <$> do
  M.BVAnd <$> pure repr <*> addElt bv1 <*> addElt bv2
crucAppToExpr (S.BVBitOr repr bv1 bv2) = AppExpr <$> do
  M.BVOr <$> pure repr <*> addElt bv1 <*> addElt bv2
crucAppToExpr (S.BVBitXor repr bv1 bv2) = AppExpr <$> do
  M.BVXor <$> pure repr <*> addElt bv1 <*> addElt bv2
crucAppToExpr _ = error "crucAppToExpr: unimplemented crucible operation"


locToReg :: (1 <= APPC.ArchRegWidth ppc,
             M.RegAddrWidth (PPCReg ppc) ~ APPC.ArchRegWidth ppc)
         => proxy ppc
         -> APPC.Location ppc ctp
         -> PPCReg ppc (FromCrucibleBaseType ctp)
locToReg _ (APPC.LocGPR gpr) = PPC_GP gpr
locToReg _  APPC.LocIP       = PPC_IP
locToReg _  APPC.LocLNK      = PPC_LNK
locToReg _  APPC.LocCTR      = PPC_CTR
locToReg _  APPC.LocCR       = PPC_CR
locToReg _  _                = undefined
-- fill the rest out later

-- | Given a location to modify and a crucible formula, construct a PPCGenerator that
-- will modify the location by the function encoded in the formula.
interpretFormula :: forall ppc t ctp s ids
                  . (PPCArchConstraints ppc, 1 <= APPC.ArchRegWidth ppc, M.RegAddrWidth (PPCReg ppc) ~ APPC.ArchRegWidth ppc)
                 => APPC.Location ppc ctp
                 -> S.Elt t ctp
                 -> PPCGenerator ppc ids s ()
interpretFormula loc elt = do
  expr <- eltToExpr elt
  let reg  = (locToReg (Proxy @ppc) loc)
  case expr of
    ValueExpr val -> setRegVal reg val
    AppExpr app -> do
      assignment <- addAssignment (M.EvalApp app)
      setRegVal reg (M.AssignedValue assignment)

-- Convert a Crucible element into an expression.
eltToExpr :: M.ArchConstraints ppc => S.Elt t ctp -> PPCGenerator ppc ids s (Expr ppc ids (FromCrucibleBaseType ctp))
eltToExpr (S.BVElt w val _) = return $ ValueExpr (M.BVValue w val)
eltToExpr (S.AppElt appElt) = crucAppToExpr (S.appEltApp appElt)
eltToExpr _ = undefined

-- Add a Crucible element in the PPCGenerator monad.
addElt :: M.ArchConstraints ppc => S.Elt t ctp -> PPCGenerator ppc ids s (M.Value ppc ids (FromCrucibleBaseType ctp))
addElt elt = eltToExpr elt >>= addExpr
