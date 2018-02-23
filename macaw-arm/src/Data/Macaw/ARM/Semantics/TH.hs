{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Data.Macaw.ARM.Semantics.TH
    ( armAppEvaluator
    , armNonceAppEval
    )
    where

import qualified Data.Functor.Const as C
import           Data.Macaw.ARM.ARMReg
import qualified Data.Macaw.CFG as M
import qualified Data.Macaw.SemMC.Operands as O
import           Data.Macaw.SemMC.TH ( symFnName, asName )
import           Data.Macaw.SemMC.TH.Monad
import qualified Data.Macaw.Types as M
import           Data.Parameterized.Classes
import qualified Data.Parameterized.Map as Map
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Parameterized.TraversableFC as FC
import           Data.Proxy ( Proxy(..) )
import           Data.Semigroup
import           GHC.TypeLits
import qualified Lang.Crucible.Solver.SimpleBuilder as S
import           Language.Haskell.TH
import qualified SemMC.Architecture as A
import qualified SemMC.Architecture.ARM.Eval as AE
import qualified SemMC.Architecture.ARM.Location as Loc
import qualified SemMC.Architecture.Location as L


-- n.b. although MacawQ is a monad and therefore has a fail
-- definition, using error provides *much* better error diagnostics
-- than fail does.


-- | Called to evaluate architecture-specific applications in the
-- current Nonce context.  If this is not recognized as an
-- architecture-specific Application, return Nothing, in which case
-- the caller will try the set of default Application evaluators.
armNonceAppEval :: forall arch t tp
                 . (A.Architecture arch,
                    L.Location arch ~ Loc.Location arch,
                    1 <= Loc.ArchRegWidth arch,
                    M.RegAddrWidth ARMReg ~ Loc.ArchRegWidth arch)
                => BoundVarInterpretations arch t
                -> S.NonceApp t (S.Elt t) tp
                -> Maybe (MacawQ arch t Exp)
armNonceAppEval bvi nonceApp =
    -- The default nonce app eval (defaultNonceAppEvaluator in
    -- macaw-semmc:Data.Macaw.SemMC.TH) will search the
    -- A.locationFuncInterpretation alist already, and there's nothing
    -- beyond that needed here, so just handle special cases here
    case nonceApp of
      S.FnApp symFn args ->
          let nm = symFnName symFn
          in case nm of
               "arm_is_r15" -> return $
                   -- This requires special handling because this can
                   -- be checking actual GPR locations or the results
                   -- of an expression extracting a register number
                   -- from an operand (i.e. a NonceAppElt), and the
                   -- appropriate interpIsR15 instance should be
                   -- applied to the result
                   case FC.toListFC Some args of
                     [Some operand] -> do
                       -- The operand can be either a variable (TH name bound from
                       -- matching on the instruction operand list) or a call on such.
                       case operand of
                         S.BoundVarElt bv ->
                             case Map.lookup bv (opVars bvi) of
                               Just (C.Const name) -> liftQ [| O.extractValue (AE.interpIsR15 $(varE name)) |]
                               Nothing -> fail ("arm_is_15 bound var not found: " ++ show bv)
                         S.NonceAppElt nonceApp' ->
                             case S.nonceEltApp nonceApp' of
                               S.FnApp symFn' args' ->
                                   let recName = symFnName symFn' in
                                   case lookup recName (A.locationFuncInterpretation (Proxy @arch)) of
                                     Nothing -> fail ("Unsupported arm_is_r15 UF: " ++ recName)
                                     Just fi ->
                                         case FC.toListFC (asName nm bvi) args' of
                                           [] -> fail ("zero-argument arm_is_r15 uninterpreted functions\
                                                       \ are not supported: " ++ nm)
                                           argNames ->
                                               let call = appE (varE (A.exprInterpName fi)) $ foldr1 appE (map varE argNames)
                                               in liftQ [| O.extractValue (AE.interpIsR15 ($(call))) |]
                               _ -> fail ("Unsupported arm.is_r15 nonce app type")
                         _ -> fail "Unsupported operand to arm.is_r15"
                     _ -> fail ("Invalid argument list for arm.is_r15: " ++ showF args)
               _ -> Nothing -- fallback to default handling
      _ -> Nothing -- fallback to default handling




-- ----------------------------------------------------------------------

armAppEvaluator :: (L.Location arch ~ Loc.Location arch,
                    A.Architecture arch,
                    1 <= Loc.ArchRegWidth arch,
                    M.RegAddrWidth ARMReg ~ Loc.ArchRegWidth arch)
                => BoundVarInterpretations arch t
                -> S.App (S.Elt t) ctp
                -> Maybe (MacawQ arch t Exp)
armAppEvaluator interps elt =
    case elt of
      -- S.NoPrimKnown w rhs -> return $ do e1 <- addEltTH interps rhs
      --                                   liftQ [| let npkExp = NoPrimKnown $(natReprTH w) $(return e1)
      --                                            in (G.ValueExpr . M.AssignedValue) <$> G.addAssignment (M.EvalArchFn noPrimKnown (M.typeRepr noPrimKnown))
      --                                         |]
      _ -> Nothing
