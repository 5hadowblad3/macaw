{-|
Copyright        : (c) Galois, Inc 2015-2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>

This defines the core operations for mapping from Reopt to Crucible.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wwarn #-}
module Data.Macaw.Symbolic.App
  ( ArchTranslateFunctions(..)
  , MacawMonad
  , addMacawBlock
  ) where

import           Control.Lens
import           Control.Monad.Except
import           Control.Monad.ST
import           Control.Monad.State.Strict
import           Data.Bits
import qualified Data.Macaw.CFG as M
import qualified Data.Macaw.CFG.Block as M
import qualified Data.Macaw.Memory as M
import qualified Data.Macaw.Types as M
import qualified Data.Map.Strict as Map
import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.NatRepr
import           Data.Parameterized.TraversableFC
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Text as Text
import           Data.Word
import qualified Lang.Crucible.CFG.Expr as C
import qualified Lang.Crucible.CFG.Reg as CR
import qualified Lang.Crucible.FunctionHandle as C
import           Lang.Crucible.ProgramLoc as C
import qualified Lang.Crucible.Solver.Symbol as C
import qualified Lang.Crucible.Types as C

import           Data.Macaw.Symbolic.PersistentState

------------------------------------------------------------------------
-- CrucPersistentState

-- | Architecture-specific information needed to translate from Macaw to Crucible
data ArchTranslateFunctions arch
  = ArchTranslateFunctions
  { archRegNameFn :: !(forall tp . M.ArchReg arch tp -> C.SolverSymbol)
  , archRegAssignment :: !(Ctx.Assignment (M.ArchReg arch) (ArchRegContext arch))
    -- ^ Map from indices in the ArchRegContext to the associated register.
  , archTranslateFn :: !(forall ids s tp
                         . M.ArchFn arch (M.Value arch ids) tp
                         -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp)))
     -- ^ Function for translating an architecture specific function
  , archTranslateStmt :: !(forall ids s . M.ArchStmt arch (M.Value arch ids) -> CrucGen arch ids s ())
  , archTranslateTermStmt :: !(forall ids s
                               . M.ArchTermStmt arch ids
                               -> M.RegState (M.ArchReg arch) (M.Value arch ids)
                               -> CrucGen arch ids s ())
  }

-- | State used for generating blocks
data CrucGenState arch ids s
   = CrucGenState
   { translateFns :: !(ArchTranslateFunctions arch)
   , crucCtx :: !(CrucGenContext arch ids s)
   , crucPState :: !(CrucPersistentState arch ids s)
     -- ^ State that persists across blocks.
   , blockLabel :: (CR.Label s)
     -- ^ Label for this block we are translating
   , macawBlockIndex :: !Word64
   , codeAddr :: !Word64
     -- ^ Address of this code
   , prevStmts :: ![C.Posd (CR.Stmt s)]
     -- ^ List of states in reverse order
   }

crucPStateLens :: Simple Lens (CrucGenState arch ids s) (CrucPersistentState arch ids s)
crucPStateLens = lens crucPState (\s v -> s { crucPState = v })

assignValueMapLens :: Simple Lens (CrucGenState arch ids s)
                                  (MapF (M.AssignId ids) (MacawCrucibleValue (CR.Atom s)))
assignValueMapLens = crucPStateLens . lens assignValueMap (\s v -> s { assignValueMap = v })

newtype CrucGen arch ids s r
   = CrucGen { unContGen
               :: CrucGenState arch ids s
                  -> (CrucGenState arch ids s -> r -> ST s (CrucPersistentState arch ids s))
                  -> ST s (CrucPersistentState arch ids s)
             }

instance Functor (CrucGen arch ids s) where
  fmap f m = CrucGen $ \s0 cont -> unContGen m s0 $ \s1 v -> cont s1 (f v)

instance Applicative (CrucGen arch ids s) where
  pure r = CrucGen $ \s cont -> cont s r
  mf <*> ma = CrucGen $ \s0 cont -> unContGen mf s0
                      $ \s1 f -> unContGen ma s1
                      $ \s2 a -> cont s2 (f a)

instance Monad (CrucGen arch ids s) where
  m >>= h = CrucGen $ \s0 cont -> unContGen m s0 $ \s1 r -> unContGen (h r) s1 cont

instance MonadState (CrucGenState arch ids s) (CrucGen arch ids s) where
  get = CrucGen $ \s cont -> cont s s
  put s = CrucGen $ \_ cont -> cont s ()

getCtx :: CrucGen arch ids s (CrucGenContext arch ids s)
getCtx = gets crucCtx

liftST :: ST s r -> CrucGen arch ids s r
liftST m = CrucGen $ \s cont -> m >>= cont s


-- | Get current position
getPos :: CrucGen arch ids s C.Position
getPos = do
  ctx <- getCtx
  C.BinaryPos (binaryPath ctx) <$> gets codeAddr

addStmt :: CR.Stmt s -> CrucGen arch ids s ()
addStmt stmt = seq stmt $ do
  p <- getPos
  s <- get
  let pstmt = C.Posd p stmt
  seq pstmt $ do
  put $! s { prevStmts = pstmt : prevStmts s }

addTermStmt :: CR.TermStmt s (MacawFunctionResult arch)
            -> CrucGen arch ids s a
addTermStmt tstmt = do
  termPos <- getPos
  CrucGen $ \s _ -> do
  let lbl = CR.LabelID (blockLabel s)
  let stmts = Seq.fromList (reverse (prevStmts s))
  let term = C.Posd termPos tstmt
  let blk = CR.mkBlock lbl Set.empty stmts term
  pure $!  crucPState s & seenBlockMapLens %~ Map.insert (macawBlockIndex s) blk

freshValueIndex :: CrucGen arch ids s Int
freshValueIndex = do
  s <- get
  let ps = crucPState s
  let cnt = valueCount ps
  put $! s { crucPState = ps { valueCount = cnt + 1 } }
  pure $! cnt

-- | Evaluate the crucible app and return a reference to the result.
evalAtom :: CR.AtomValue s ctp -> CrucGen arch ids s (CR.Atom s ctp)
evalAtom av = do
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
crucibleValue :: C.App (CR.Atom s) ctp -> CrucGen arch ids s (CR.Atom s ctp)
crucibleValue app = evalAtom (CR.EvalApp app)

-- | Evaluate the crucible app and return a reference to the result.
getRegInput :: Ctx.Assignment (M.ArchReg arch) (ArchRegContext arch)
            -> IndexPair (ArchRegContext arch) tp
            -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
getRegInput regAssign idx = do
  ctx <- getCtx
  archConstraints ctx $ do
  -- Make atom
  let regStruct = CR.Atom { CR.atomPosition = C.InternalPos
                          , CR.atomId = 0
                          , CR.atomSource = CR.FnInput
                          , CR.typeOfAtom = regStructRepr ctx
                          }
  let tp = M.typeRepr (regAssign Ctx.! macawIndex idx)
  crucibleValue (C.GetStruct regStruct (crucibleIndex idx) (typeToCrucible tp))

v2c :: M.Value arch ids tp
    -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
v2c = valueToCrucible

-- | Evaluate the crucible app and return a reference to the result.
appAtom :: C.App (CR.Atom s) ctp -> CrucGen arch ids s (CR.Atom s ctp)
appAtom app = evalAtom (CR.EvalApp app)

-- | Create a crucible value for a bitvector literal.
bvLit :: (1 <= w) => NatRepr w -> Integer -> CrucGen arch ids s (CR.Atom s (C.BVType w))
bvLit w i = crucibleValue (C.BVLit w (i .&. maxUnsigned w))

incNatIsPos :: forall p w . p w -> LeqProof 1 (w+1)
incNatIsPos _ = leqAdd2 (LeqProof :: LeqProof 0 w) (LeqProof :: LeqProof 1 1)

zext1 :: forall arch ids s w
      .  (1 <= w)
      => NatRepr w
      -> CR.Atom s (C.BVType w)
      -> CrucGen arch ids s (CR.Atom s (C.BVType (w+1)))
zext1 w =
  case incNatIsPos w of
    LeqProof -> appAtom . C.BVZext (incNat w) w

msb :: (1 <= w) => NatRepr w -> CR.Atom s (C.BVType w) -> CrucGen arch ids s (CR.Atom s C.BoolType)
msb w x = do
  mask <- bvLit w (maxSigned w + 1)
  x_mask <- appAtom $ C.BVAnd w x mask
  appAtom (C.BVEq w x_mask mask)

bvAdc :: (1 <= w)
      => NatRepr w
      -> CR.Atom s (C.BVType w)
      -> CR.Atom s (C.BVType w)
      -> CR.Atom s C.BoolType
      -> CrucGen arch ids s (CR.Atom s (C.BVType w))
bvAdc w x y c = do
  s  <- appAtom $ C.BVAdd w x y
  cbv <- appAtom =<< C.BVIte c w <$> bvLit w 1 <*> bvLit w 0
  appAtom $ C.BVAdd w s cbv


appToCrucible :: M.App (M.Value arch ids) tp
              -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
appToCrucible app = do
  ctx <- getCtx
  archConstraints ctx $ do
  case app of
    M.Eq x y ->
      case M.typeRepr x of
        M.BoolTypeRepr -> do
          eq <- appAtom =<< C.BoolXor <$> v2c x <*> v2c y
          appAtom (C.Not eq)
        M.BVTypeRepr w -> do
          appAtom =<< C.BVEq w <$> v2c x <*> v2c y
        M.TupleTypeRepr _ -> undefined -- TODO: Fix this
    M.Mux tp c t f ->
      case tp of
        M.BoolTypeRepr ->
          appAtom =<< C.BoolIte <$> v2c c <*> v2c t <*> v2c f
        M.BVTypeRepr w ->
          appAtom =<< C.BVIte <$> v2c c <*> pure w <*> v2c t <*> v2c f
        M.TupleTypeRepr _ -> undefined -- TODO: Fix this
    M.Trunc x w -> appAtom =<< C.BVTrunc w (M.typeWidth x) <$> v2c x
    M.SExt x w  -> appAtom =<< C.BVSext  w (M.typeWidth x) <$> v2c x
    M.UExt x w  -> appAtom =<< C.BVZext  w (M.typeWidth x) <$> v2c x
    M.AndApp x y  -> appAtom =<< C.And     <$> v2c x <*> v2c y
    M.OrApp  x y  -> appAtom =<< C.Or      <$> v2c x <*> v2c y
    M.NotApp x    -> appAtom =<< C.Not     <$> v2c x
    M.XorApp x y  -> appAtom =<< C.BoolXor <$> v2c x <*> v2c y
    M.BVAdd w x y -> appAtom =<< C.BVAdd w <$> v2c x <*> v2c y
    M.BVSub w x y -> appAtom =<< C.BVSub w <$> v2c x <*> v2c y
    M.BVMul w x y -> appAtom =<< C.BVMul w <$> v2c x <*> v2c y
    M.BVUnsignedLe x y -> appAtom =<< C.BVUle (M.typeWidth x) <$> v2c x <*> v2c y
    M.BVUnsignedLt x y -> appAtom =<< C.BVUlt (M.typeWidth x) <$> v2c x <*> v2c y
    M.BVSignedLe   x y -> appAtom =<< C.BVSle (M.typeWidth x) <$> v2c x <*> v2c y
    M.BVSignedLt   x y -> appAtom =<< C.BVSlt (M.typeWidth x) <$> v2c x <*> v2c y
    M.BVTestBit x i -> do
      let w = M.typeWidth x
      one <- bvLit w 1
      -- Create mask for ith index
      i_mask <- appAtom =<< C.BVShl w one <$> v2c i
      -- Mask off index
      x_mask <- appAtom =<< C.BVAnd w <$> v2c x <*> pure i_mask
      -- Check to see if result is i_mask
      appAtom (C.BVEq w x_mask i_mask)
    M.BVComplement w x -> appAtom =<< C.BVNot w <$> v2c x
    M.BVAnd w x y -> appAtom =<< C.BVAnd w <$> v2c x <*> v2c y
    M.BVOr  w x y -> appAtom =<< C.BVOr  w <$> v2c x <*> v2c y
    M.BVXor w x y -> appAtom =<< C.BVXor w <$> v2c x <*> v2c y
    M.BVShl w x y -> appAtom =<< C.BVShl  w <$> v2c x <*> v2c y
    M.BVShr w x y -> appAtom =<< C.BVLshr w <$> v2c x <*> v2c y
    M.BVSar w x y -> appAtom =<< C.BVAshr w <$> v2c x <*> v2c y

    M.UadcOverflows x y c -> do
      let w  = M.typeWidth x
      let w' = incNat w
      x' <- zext1 w =<< v2c x
      y' <- zext1 w =<< v2c y
      LeqProof <- pure (incNatIsPos w)
      r <- bvAdc w' x' y' =<< v2c c
      msb w' r
    M.SadcOverflows x y c -> do
      undefined x y c
    M.UsbbOverflows x y b -> do
      undefined x y b
    M.SsbbOverflows x y b -> do
      undefined x y b
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
  cns <- archConstraints <$> getCtx
  cns $ do
  case v of
    M.BVValue w c -> bvLit w c
    M.BoolValue b -> crucibleValue (C.BoolLit b)
    -- In this case,
    M.RelocatableValue w addr
      | M.addrBase addr == 0 ->
        crucibleValue (C.BVLit w (toInteger (M.addrOffset addr)))
      | otherwise -> do
          let idx = M.addrBase addr
          segMap <- memBaseAddrMap <$> getCtx
          case Map.lookup idx segMap of
            Just g -> do
              a <- evalAtom (CR.ReadGlobal g)
              offset <- crucibleValue (C.BVLit w (toInteger (M.addrOffset addr)))
              crucibleValue (C.BVAdd w a offset)
            Nothing ->
              fail $ "internal: No Crucible address associated with segment."
    M.Initial r -> do
      ctx <- getCtx
      case MapF.lookup r (regIndexMap ctx) of
        Just idx -> do
          getRegInput (macawRegAssign ctx) idx
        Nothing -> fail $ "internal: Register is not bound."
    M.AssignedValue asgn -> do
      let idx = M.assignId asgn
      amap <- use assignValueMapLens
      case MapF.lookup idx amap of
        Just (MacawCrucibleValue r) -> pure r
        Nothing ->  fail "internal: Assignment id is not bound."

mkHandleVal :: HandleId arch '(args,ret)
            -> CrucGen arch ids s (C.FnHandle args ret)
mkHandleVal hid = do
  hmap <- use $ crucPStateLens . handleMapLens
  case MapF.lookup hid hmap of
    Just (HandleVal h) -> pure h
    Nothing -> do
      ctx <- getCtx
      let argTypes = handleIdArgTypes ctx hid
      let retType = handleIdRetType ctx hid
      hndl <- liftST $ C.mkHandle' (handleAlloc ctx) (handleIdName hid) argTypes retType
      crucPStateLens . handleMapLens %= MapF.insert hid (HandleVal hndl)
      pure $! hndl

-- | Call a function handle
callFnHandle :: C.FnHandle args ret
                -- ^ Handle to call
             -> Ctx.Assignment (CR.Atom s) args
                -- ^ Arguments to function
             -> CrucGen arch ids s (CR.Atom s ret)
callFnHandle hndl args = do
  hatom <- crucibleValue (C.HandleLit hndl)
  evalAtom $ CR.Call hatom args (C.handleReturnType hndl)

-- | Create a fresh symbolic value of the given type.
freshSymbolic :: M.TypeRepr tp
              -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
freshSymbolic repr = do
  hndl <- mkHandleVal (MkFreshSymId repr)
  callFnHandle hndl Ctx.empty

-- | Read the given memory address
readMem :: M.ArchAddrValue arch ids
        -> M.MemRepr tp
        -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
readMem addr repr = do
  hndl <- mkHandleVal (ReadMemId repr)
  caddr <- valueToCrucible addr
  callFnHandle hndl (Ctx.empty Ctx.%> caddr)

writeMem :: M.ArchAddrValue arch ids
        -> M.MemRepr tp
        -> M.Value arch ids tp
        -> CrucGen arch ids s ()
writeMem addr repr val = do
  hndl <- mkHandleVal (WriteMemId repr)
  caddr <- valueToCrucible addr
  cval  <- valueToCrucible val
  let args = Ctx.empty Ctx.%> caddr Ctx.%> cval
  void $ callFnHandle hndl args

assignRhsToCrucible :: M.AssignRhs arch (M.Value arch ids) tp
                    -> CrucGen arch ids s (CR.Atom s (ToCrucibleType tp))
assignRhsToCrucible rhs =
  case rhs of
    M.EvalApp app -> appToCrucible app
    M.SetUndefined mrepr -> freshSymbolic mrepr
    M.ReadMem addr repr -> readMem addr repr
    M.EvalArchFn f _ -> do
      fns <- translateFns <$> get
      archTranslateFn fns f

addMacawStmt :: M.Stmt arch ids -> CrucGen arch ids s ()
addMacawStmt stmt =
  case stmt of
    M.AssignStmt asgn -> do
      let idx = M.assignId asgn
      a <- assignRhsToCrucible (M.assignRhs asgn)
      assignValueMapLens %= MapF.insert idx (MacawCrucibleValue a)
    M.WriteMem addr repr val -> do
      writeMem addr repr val
    M.PlaceHolderStmt _vals msg -> do
      cmsg <- crucibleValue (C.TextLit (Text.pack msg))
      addTermStmt (CR.ErrorStmt cmsg)
    M.InstructionStart _addr _ -> do
      -- TODO: Fix this
      pure ()
    M.Comment _txt -> do
      pure ()
    M.ExecArchStmt astmt -> do
      fns <- translateFns <$> get
      archTranslateStmt fns astmt

lookupCrucibleLabel :: Word64 -> CrucGen arch ids s (CR.Label s)
lookupCrucibleLabel idx = do
  m <- macawIndexToLabelMap <$> getCtx
  case Map.lookup idx m of
    Nothing -> fail $ "Could not find label for block " ++ show idx
    Just l -> pure l

-- | Create a crucible struct for registers from a register state.
createRegStruct :: forall arch ids s
                .  M.RegState (M.ArchReg arch) (M.Value arch ids)
                -> CrucGen arch ids s (CR.Atom s (ArchRegStruct arch))
createRegStruct regs = do
  ctx <- getCtx
  archConstraints ctx $ do
  let regAssign = macawRegAssign ctx
  let tps = fmapFC M.typeRepr regAssign
  let a = fmapFC (\r -> regs ^. M.boundValue r) regAssign
  fields <- macawAssignToCrucM valueToCrucible a
  crucibleValue $ C.MkStruct (typeCtxToCrucible tps) fields

addMacawTermStmt :: M.TermStmt arch ids -> CrucGen arch ids s ()
addMacawTermStmt tstmt =
  case tstmt of
    M.FetchAndExecute regs -> do
      s <- createRegStruct regs
      addTermStmt (CR.Return s)
    M.Branch macawPred macawTrueLbl macawFalseLbl -> do
      p <- valueToCrucible macawPred
      t <- lookupCrucibleLabel macawTrueLbl
      f <- lookupCrucibleLabel macawFalseLbl
      addTermStmt (CR.Br p t f)
    M.ArchTermStmt ts regs -> do
      fns <- translateFns <$> get
      archTranslateTermStmt fns ts regs
    M.TranslateError _regs msg -> do
      cmsg <- crucibleValue (C.TextLit msg)
      addTermStmt (CR.ErrorStmt cmsg)

-- | Type level monad for building blocks.
type MacawMonad arch ids s = ExceptT String (StateT (CrucPersistentState arch ids s) (ST s))

addMacawBlock :: ArchTranslateFunctions arch
              -> CrucGenContext arch ids s
              -> Word64
                 -- ^ Code address
              -> M.Block arch ids
              -> MacawMonad arch ids s ()
addMacawBlock tfns ctx addr b = do
  pstate <- get
  let idx = M.blockLabel b
  lbl <-
    case Map.lookup idx (macawIndexToLabelMap ctx) of
      Just lbl -> pure lbl
      Nothing -> throwError $ "Internal: Could not find block with index " ++ show idx
  let s0 = CrucGenState { translateFns = tfns
                        , crucCtx = ctx
                        , crucPState = pstate
                        , blockLabel = lbl
                        , macawBlockIndex = idx
                        , codeAddr = addr
                        , prevStmts = []
                        }
  let cont _s () = fail "Unterminated crucible block"
  let action = do
        mapM_ addMacawStmt (M.blockStmts b)
        addMacawTermStmt (M.blockTerm b)
  r <- lift $ lift $ unContGen action s0 cont
  put r
