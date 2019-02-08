{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
-- | This module uses symbolic evaluation to refine the discovered CFG
-- and resolve unknown transfer classify failures.
--
-- One of the primary refinements possible via this module is the
-- ability to determine transfer targets that were previously
-- undiscoverable.
--
-- For example (roughly tests/samples/switching.c):
--
-- > int retval(int n) {
-- >   switch (n) {
-- >     case 0: ...;
-- >     case 1: ...;
-- >     case 3: ...;
-- >     default: 0;
-- >   }
-- > }
--
-- In the above, the body of each case is relatively small and similar
-- to the others, so the compiler decides not to generate a series of
-- 'cmp n, VAL; jeq CASETGT' instructions, but instead computes an
-- offset based on the maximum size of each case body * n and adds
-- that to the current address.
--
-- discovery:
--   block 1 "setup": terminate with: ite r28 @default-handler @cases-handler
--   block 2 "cases-handler": calculates jump offset for case values, CLASSIFY FAILURE: unknown transfer
--   block 3 "default-handler": terminate with return
--
-- In this example, the jump offset for case values is range-limited
-- by block 1, but block 2 doesn't see that, and also because of that
-- the block(s) corresponding to the case conditions are not
-- discovered.  The goal of the code in this module is to improve
-- this, using SMT analysis.
--
-- First, a What4 formula is generated for block 2 and this is
-- provided to Crucible to identify possible jump targets.  The result
-- should be a nearly infinite number of targets (every "case body
-- size" offset), which Macaw could constrain to the valid text region
-- (although the jumps beyond the text region could arguably be
-- flagged as errors).
--
-- However, by adding the precursor block (block 1) and computing the
-- SMT formula for block 1 + block2, the result of the jump is only
-- the actual case targets, and thus this is a smaller solution (and
-- therefore better) than the previous step.
--
-- The algorithm should continue to iterate back through the blocks to
-- achieve better and better (i.e. smaller) solutions until reaching
-- the entry point of the function itself, or until reaching a point
-- where the solution symbolically diverges (e.g. a loop with a
-- variable exit condition).
--
-- It might be considered an optimization to simply skip the
-- iterations and try to solve from the start of the function to the
-- unknown transfer point, but if there are symbolically-divergent
-- loops in that path the result will be unconstrained (see Note 1).
--
-- In the worst case, the SMT analysis is unable to further refine the
-- information and this block is still noted as an unkown transfer, so
-- it has not worsened the analysis, even though it has not improved
-- it.
--
-- If the refinement does yield a smaller set of functions, that can
-- be identified as the valid targets from this block (e.g. a nested
-- ite), and additionally those targets should be subject to further
-- discovery by Macaw.
--
-- --------------------
-- Note 1: It's theoretically possible that the loop would affect the
-- constraints, but in practice this is fairly unrealistic.  A
-- completely unbounded jump is unlikely to ever be generated for
-- valid compiled C code:
--
-- > int jumpto(int n) {
-- >    (void)(*funcaddr)() = n * 32 + &jumpto;   // unrealistic
-- >    (*funcaddr)();
-- > }
--
-- A jump computation is generally only to target symbols known to the
-- C compiler, and while a section of code that cannot be symbolically
-- resolved (e.g. a symbolically-divergent loop) might *constrain* the
-- target set, the analysis of the portion following the loop should
-- reveal the total set of valid targets:
--
-- > int jumpfor(int n, int l) {
-- >    (int)(*funcs)()[6] = { &jumptgt1, &jumptgt2, ... };
-- >    int tgtnum = n % 3;
-- >    for (int j = 0; j < l; j++) {
-- >      if (j ^ n == 5)
-- >        tgtnum *= 2;
-- >    }
-- >    return (*(funcs[tgtnum]))();
-- > }
--
-- In this case, we hope to discover that the target of the jumps is
-- constrained to the entries in the funcs array, even though the loop
-- cannot be evaluated.


module Data.Macaw.Refinement.UnknownTransfer
  ( symbolicUnkTransferRefinement
  )
where

import           GHC.TypeLits

import Control.Lens
import Control.Monad ( foldM, forM )
import Control.Monad.ST ( RealWorld, stToIO )
import Control.Monad.IO.Class ( MonadIO, liftIO )
import qualified Data.Macaw.BinaryLoader as MBL
import qualified Data.Macaw.CFG as MC
import Data.Macaw.CFG.AssignRhs ( ArchSegmentOff )
import qualified Data.Macaw.CFG.Rewriter as RW
import Data.Macaw.CFG.Block ( TermStmt(..) )
import Data.Macaw.Discovery ( DiscoveryFunInfo
                            , DiscoveryState(..)
                            , ParsedBlock(..)
                            , ParsedTermStmt(ClassifyFailure)
                            , BlockTermRewriter
                            , addDiscoveredFunctionBlockTargets
                            , blockStatementList
                            , discoveredFunAddr
                            , funInfo
                            , parsedBlocks
                            , stmtsTerm
                            )
import Data.Macaw.Refinement.FuncBlockUtils ( BlockIdentifier(..), blockID
                                            , getBlock )
import Data.Macaw.Refinement.Path ( FuncBlockPath(..)
                                  , buildFuncPath, pathDepth, pathForwardTrails
                                  , pathTo, takePath )
import qualified Data.Macaw.Symbolic as MS
import qualified Data.Macaw.Symbolic.Memory as MSM
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.Parameterized.Context as Ctx
import Data.Parameterized.Nonce
import Data.Parameterized.Some
import Data.Proxy ( Proxy(..) )
import qualified Lang.Crucible.Backend as C
import qualified Lang.Crucible.Backend.Online as C
import qualified Lang.Crucible.CFG.Core as C
import qualified Lang.Crucible.FunctionHandle as C
import qualified Lang.Crucible.LLVM.DataLayout as LLVM
import qualified Lang.Crucible.LLVM.Intrinsics as LLVM
import qualified Lang.Crucible.LLVM.MemModel as LLVM
import qualified Lang.Crucible.Simulator as C
import qualified Lang.Crucible.Simulator.GlobalState as C
import           System.IO as IO
import qualified What4.Concrete as W
import qualified What4.Expr.GroundEval as W
import qualified What4.Interface as W
import qualified What4.ProgramLoc as W
import qualified What4.Protocol.Online as W
import qualified What4.Protocol.SMTLib2 as W
import qualified What4.SatResult as W
import qualified What4.Solver.Z3 as W

import           Text.PrettyPrint.ANSI.Leijen as PP hiding ((<$>))


-- | This is the main entrypoint, which is given the current Discovery
-- information and which attempts to resolve UnknownTransfer
-- classification failures, returning (possibly updated) Discovery
-- information.
symbolicUnkTransferRefinement
  :: (MS.SymArchConstraints arch, 16 <= MC.ArchAddrWidth arch, MonadIO m)
  => MBL.LoadedBinary arch bin
  -> DiscoveryState arch
  -> m (DiscoveryState arch)
symbolicUnkTransferRefinement bin inpDS =
  refineFunctions bin inpDS mempty $ allFuns inpDS


-- | Returns the list of DiscoveryFunInfo for a DiscoveryState
allFuns :: DiscoveryState arch -> [Some (DiscoveryFunInfo arch)]
allFuns ds = ds ^. funInfo . to Map.elems


-- | This iterates through the functions in the DiscoveryState to find
-- those which have transfer failures and attempts to refine the
-- transfer failure.  There are three cases:
--
--  1. The function has no transfer failures
--  2. The function has a transfer failure, but cannot be refined
--  3. The function has a transfer failure that was refined
--
-- For both #1 and #2, the action is to move to the next function.
-- For #3, the refinement process had to re-perform discovery (the
-- refinement may have added new previously undiscovered blocks that
-- may themselves have transfer failures) and so the DiscoveryState is
-- updated with the new function; this is a *new* function so it
-- cannot continue to try to refine the existing function.
--
-- Also note that because the Discovery process has to be re-done from
-- scratch for a function each time there are new transfer solutions,
-- all *previous* transfer solutions for that function must also be
-- applied.
refineFunctions
  :: ( MS.SymArchConstraints arch
     , 16 <= MC.ArchAddrWidth arch
     , MonadIO m
     ) =>
     MBL.LoadedBinary arch bin
  -> DiscoveryState arch
  -> Solutions arch -- ^ accumulated solutions so-far
  -> [Some (DiscoveryFunInfo arch)]
  -> m (DiscoveryState arch)
refineFunctions _   inpDS _ [] = pure inpDS
refineFunctions bin inpDS solns (Some fi:fis) =
  refineTransfers bin inpDS solns fi [] >>= \case
    Nothing -> refineFunctions bin inpDS solns fis  -- case 1 or 2
    Just (updDS, solns') ->
      refineFunctions bin updDS solns' $ allFuns updDS -- case 3


-- | This attempts to refine the passed in function.  There are three
-- cases:
--
--   1. The function has no unknown transfers: no refinement needed
--
--   2. An unknown transfer was refined successfully.  This resulted
--      in a new DiscoveryState, with a new Function (replacing the
--      old function).  The new Function may have new blocks that need
--      refinement, but because this is a new function the "current"
--      function cannot be refined anymore, so return 'Just' this
--      updated DiscoveryState.
--
--   3. The unknown transfer could not be refined: move to the next
--      block in this function with an unknown transfer target and
--      recursively attempt to resolve that one.
--
--   4. All unknown transfer blocks were unable to be refined: the
--   original function is sufficient.
refineTransfers
  :: ( MS.SymArchConstraints arch
     , 16 <= MC.ArchAddrWidth arch
     , MonadIO m
     ) =>
     MBL.LoadedBinary arch bin
  -> DiscoveryState arch
  -> Solutions arch
  -> DiscoveryFunInfo arch ids
  -> [BlockIdentifier arch ids]
  -> m (Maybe (DiscoveryState arch, Solutions arch))
refineTransfers bin inpDS solns fi failedRefines = do
  let unrefineable = flip elem failedRefines . blockID
      unkTransfers = filter (not . unrefineable) $ getUnknownTransfers fi
      thisUnkTransfer = head unkTransfers
      thisId = blockID thisUnkTransfer
  if null unkTransfers
  then return Nothing
  else refineBlockTransfer bin inpDS solns fi thisUnkTransfer >>= \case
    Nothing    -> refineTransfers bin inpDS solns fi (thisId : failedRefines)
    r@(Just _) -> return r


getUnknownTransfers :: DiscoveryFunInfo arch ids
                    -> [ParsedBlock arch ids]
getUnknownTransfers fi =
  filter isUnknownTransfer $ Map.elems $ fi ^. parsedBlocks

isUnknownTransfer :: ParsedBlock arch ids -> Bool
isUnknownTransfer pb =
  case stmtsTerm (blockStatementList pb) of
    ClassifyFailure {} -> True
    _ -> False

-- | This function attempts to use an SMT solver to refine the block
-- transfer.  If the transfer can be resolved, it will update the
-- input DiscoveryState with the new block information (plus any
-- blocks newly discovered via the transfer resolution) and return
-- that.  If it was unable to refine the transfer, it will return
-- Nothing and this block will be added to the "unresolvable" list.
refineBlockTransfer
  :: ( MS.SymArchConstraints arch
     , 16 <= MC.ArchAddrWidth arch
     , MonadIO m
     ) =>
     MBL.LoadedBinary arch bin
  -> DiscoveryState arch
  -> Solutions arch
  -> DiscoveryFunInfo arch ids
  -> ParsedBlock arch ids
  -> m (Maybe (DiscoveryState arch, Solutions arch))
refineBlockTransfer bin inpDS solns fi blk =
  case pathTo (blockID blk) $ buildFuncPath fi of
    Nothing -> error "unable to find function path for block" -- internal error
    Just p -> do soln <- refinePath bin inpDS fi p (pathDepth p) 1
                 case soln of
                   Nothing -> return Nothing
                   Just sl ->
                     let solns' = Map.insert (pblockAddr blk) sl solns
                         updDS = updateDiscovery inpDS solns' fi
                     in return $ Just (updDS, solns')



updateDiscovery :: ( MC.RegisterInfo (MC.ArchReg arch)
                   , KnownNat (MC.ArchAddrWidth arch)
                   , MC.ArchConstraints arch
                   ) =>
                   DiscoveryState arch
                -> Solutions arch
                -> DiscoveryFunInfo arch ids
                -> DiscoveryState arch
updateDiscovery inpDS solns finfo =
  let funAddr = discoveredFunAddr finfo
  in addDiscoveredFunctionBlockTargets inpDS funAddr $
     guideTargets solns

guideTargets :: ( MC.RegisterInfo (MC.ArchReg arch)
                , KnownNat (MC.ArchAddrWidth arch)
                , MC.ArchConstraints arch
                )=>
                Solutions arch -- ^ all rewrites to apply to this function's blocks
             -> BlockTermRewriter arch s src tgt
guideTargets solns addr tStmt = do
  case Map.lookup addr solns of
    Nothing -> pure tStmt
    Just soln -> rewriteTS tStmt soln
  where
    -- The existing TermStmt is assumed to be a TranslateError, and
    -- further assumed to be an unknown transfer because the
    -- equation for the final ip_reg could not be analyzed to obtain
    -- a simple static address.  The tgtAddrs is supplied via
    -- additional analysis (e.g. symbolic execution via SMT solver)
    -- and yielded one or more addresses to branch to.
    --
    -- The strategy here is to insert Blocks that explicitly set IP
    -- register to the target address(es) so that parseBlocks can
    -- identify those target jumps and also continue to explore those
    -- targets.
    rewriteTS old [] = pure old  -- no targets provided, cannot rewrite
    rewriteTS old (t:[]) = do
      -- The only TermStmt that allows Block insertion is the Branch,
      -- so it must be used even if there is only one address.  If
      -- there is only one address, the explicit setting of ip_reg is
      -- to the same value on both branches, so the condition for the
      -- branch is immaterial.
      j <- jumpToTarget (regsFrom old) t
      c <- RW.rewriteApp $ testIP (regsFrom old) t
      pure $ Branch c j j
    rewriteTS old (t:ts) = do
      c <- RW.rewriteApp $ testIP (regsFrom old) t
      j <- jumpToTarget (regsFrom old) t
      o <- RW.addNewBlockFromRewrite [] =<< rewriteTS old ts
      pure $ Branch c j o

    jumpToTarget inpRegs tgt = let nbt = FetchAndExecute newRegs
                                   newRegs = inpRegs & MC.curIP .~ addrAsValue tgt
                               in RW.addNewBlockFromRewrite [] nbt

    regsFrom = \case
      TranslateError regs _ -> regs
      FetchAndExecute regs  -> regs
      o -> error $ "Unexpected previous TermStmt: " <> show (PP.pretty o)

    addrAsValue a = case MC.segoffAsAbsoluteAddr a of
                      Just a' -> MC.bvValue $ fromIntegral a'
                      Nothing -> error "Unable to determine absolute address in guideTargets"

    testIP regs v = let ipAddr = regs^.MC.curIP
                        tgtVal = addrAsValue v
                    in MC.Eq ipAddr tgtVal



refinePath :: ( MS.SymArchConstraints arch
              , 16 <= MC.ArchAddrWidth arch
              , MonadIO m
              ) =>
              MBL.LoadedBinary arch bin
           -> DiscoveryState arch
           -> DiscoveryFunInfo arch ids
           -> FuncBlockPath arch ids
           -> Int
           -> Int
           -> m (Maybe (Solution arch))
refinePath bin inpDS fi path maxlevel numlevels =
  let thispath = takePath numlevels path
      smtEquation = equationFor inpDS fi thispath
  in solve bin smtEquation >>= \case
       Nothing -> return Nothing -- divergent, stop here
       soln@(Just{}) -> if numlevels >= maxlevel
                          then return soln
                          else refinePath bin inpDS fi path maxlevel (numlevels + 1)

data Equation arch ids = Equation (DiscoveryState arch) [[ParsedBlock arch ids]]
type Solution arch = [ArchSegmentOff arch]  -- identified transfers
type Solutions arch = Map.Map (ArchSegmentOff arch) (Solution arch)


equationFor :: DiscoveryState arch
            -> DiscoveryFunInfo arch ids
            -> FuncBlockPath arch ids
            -> Equation arch ids
equationFor inpDS fi p =
  let pTrails = pathForwardTrails p
      pTrailBlocks = map (getBlock fi) <$> pTrails
  in if and (any (not . isJust) <$> pTrailBlocks)
     then error "did not find requested block in discovery results!" -- internal
       else Equation inpDS (catMaybes <$> pTrailBlocks)

solve :: ( MS.SymArchConstraints arch
         , 16 <= MC.ArchAddrWidth arch
         , MonadIO m
         ) =>
         MBL.LoadedBinary arch bin
      -> Equation arch ids
      -> m (Maybe (Solution arch))
solve bin (Equation inpDS paths) = do
  blockAddrs <- concat <$> forM paths
    (\path -> liftIO $ withDefaultRefinementContext bin $ \context ->
      smtSolveTransfer context inpDS path)
  return $ if null blockAddrs then Nothing else Just blockAddrs

--isBetterSolution :: Solution arch -> Solution arch -> Bool
-- isBetterSolution :: [ArchSegmentOff arch] -> [ArchSegmentOff arch] -> Bool
-- isBetterSolution = (<)

----------------------------------------------------------------------
-- * Symbolic execution


data RefinementContext arch t solver fp = RefinementContext
  { symbolicBackend :: C.OnlineBackend t solver fp
  , archVals :: MS.ArchVals arch
  , handleAllocator :: C.HandleAllocator RealWorld
  , nonceGenerator :: NonceGenerator IO t
  , extensionImpl :: C.ExtensionImpl (MS.MacawSimulatorState (C.OnlineBackend t solver fp)) (C.OnlineBackend t solver fp) (MS.MacawExt arch)
  , memVar :: C.GlobalVar LLVM.Mem
  , mem :: LLVM.MemImpl (C.OnlineBackend t solver fp)
  , memPtrTable :: MSM.MemPtrTable (C.OnlineBackend t solver fp) (MC.ArchAddrWidth arch)
  }

withDefaultRefinementContext
  :: forall arch a bin
   . (MS.SymArchConstraints arch, 16 <= MC.ArchAddrWidth arch)
  => MBL.LoadedBinary arch bin
  -> (forall t . RefinementContext arch t (W.Writer W.Z3) (C.Flags C.FloatIEEE) -> IO a)
  -> IO a
withDefaultRefinementContext loaded_binary k = do
  handle_alloc <- C.newHandleAllocator
  withIONonceGenerator $ \nonce_gen ->
    C.withZ3OnlineBackend nonce_gen C.NoUnsatFeatures $ \sym ->
      case MS.archVals (Proxy @arch) of
        Just arch_vals -> do
          -- path_setter <- W.getOptionSetting W.z3Path (W.getConfiguration sym)
          -- _ <- W.setOpt path_setter "z3-tee"

          mem_var <- stToIO $ LLVM.mkMemVar handle_alloc
          -- empty_mem <- LLVM.emptyMem LLVM.LittleEndian
          -- let ?ptrWidth = W.knownNat
          -- (base_ptr, allocated_mem) <- LLVM.doMallocUnbounded
          --   sym
          --   LLVM.GlobalAlloc
          --   LLVM.Mutable
          --   "flat memory"
          --   empty_mem
          --   LLVM.noAlignment
          -- let Right mem_name = W.userSymbol "mem"
          -- mem_array <- W.freshConstant sym mem_name W.knownRepr
          -- initialized_mem <- LLVM.doArrayStoreUnbounded
          --   sym
          --   allocated_mem
          --   base_ptr
          --   LLVM.noAlignment
          --   mem_array
          (mem, mem_ptr_table) <- MSM.newGlobalMemory
            (Proxy @arch)
            sym
            LLVM.LittleEndian
            MSM.ConcreteMutable
            (MBL.memoryImage loaded_binary)
          MS.withArchEval arch_vals sym $ \arch_eval_fns -> do
            let ext_impl = MS.macawExtensions
                  arch_eval_fns
                  mem_var
                  (MSM.mapRegionPointers mem_ptr_table)
                  (MS.LookupFunctionHandle $ \_ _ _ -> undefined)
            k $ RefinementContext
              { symbolicBackend = sym
              , archVals = arch_vals
              , handleAllocator = handle_alloc
              , nonceGenerator = nonce_gen
              , extensionImpl = ext_impl
              , memVar = mem_var
              -- , mem = empty_mem
              , mem = mem
              , memPtrTable = mem_ptr_table
              }
        Nothing -> fail $ "unsupported architecture"

freshSymVar
  :: (C.IsSymInterface sym, MonadIO m)
  => sym
  -> String
  -> Ctx.Index ctx tp
  -> C.TypeRepr tp
  -> m (C.RegValue' sym tp)
freshSymVar sym prefix idx tp =
  liftIO $ C.RV <$> case W.userSymbol $ prefix ++ show (Ctx.indexVal idx) of
    Right symbol -> case tp of
      LLVM.LLVMPointerRepr w ->
        LLVM.llvmPointer_bv sym
          =<< W.freshConstant sym symbol (W.BaseBVRepr w)
      C.BoolRepr ->
        W.freshConstant sym symbol W.BaseBoolRepr
      _ -> fail $ "unsupported variable type: " ++ show tp
    Left err -> fail $ show err

initRegs
  :: forall arch sym m
   . (MS.SymArchConstraints arch, C.IsSymInterface sym, MonadIO m)
  => MS.ArchVals arch
  -> sym
  -> C.RegValue sym (LLVM.LLVMPointerType (MC.ArchAddrWidth arch))
  -> C.RegValue sym (LLVM.LLVMPointerType (MC.ArchAddrWidth arch))
  -> m (C.RegMap sym (MS.MacawFunctionArgs arch))
initRegs arch_vals sym ip_val sp_val = do
  let reg_types = MS.crucArchRegTypes $ MS.archFunctions $ arch_vals
  reg_vals <- Ctx.traverseWithIndex (freshSymVar sym "reg") reg_types
  let reg_struct = C.RegEntry (C.StructRepr reg_types) reg_vals
  return $ C.RegMap $ Ctx.singleton $
    (MS.updateReg arch_vals)
      ((MS.updateReg arch_vals) reg_struct MC.ip_reg ip_val)
      MC.sp_reg
      sp_val

smtSolveTransfer
  :: ( MS.SymArchConstraints arch
     , 16 <= MC.ArchAddrWidth arch
     , C.IsSymInterface (C.OnlineBackend t solver fp)
     , W.OnlineSolver t solver
     , MonadIO m
     )
  => RefinementContext arch t solver fp
  -> DiscoveryState arch
  -> [ParsedBlock arch ids]
  -> m [ArchSegmentOff arch]
smtSolveTransfer RefinementContext{..} discovery_state blocks = do
  let ?ptrWidth = W.knownNat

  let Right stack_name = W.userSymbol "stack"
  stack_array <- liftIO $ W.freshConstant symbolicBackend stack_name C.knownRepr
  stack_size <- liftIO $ W.bvLit symbolicBackend ?ptrWidth $ 2 * 1024 * 1024
  (stack_base_ptr, mem1) <- liftIO $ LLVM.doMalloc
    symbolicBackend
    LLVM.StackAlloc
    LLVM.Mutable
    "stack_alloc"
    mem
    stack_size
    LLVM.noAlignment

  mem2 <- liftIO $ LLVM.doArrayStore
    symbolicBackend
    mem1
    stack_base_ptr
    LLVM.noAlignment
    stack_array
    stack_size
  init_sp_val <- liftIO $ LLVM.ptrAdd symbolicBackend C.knownRepr stack_base_ptr stack_size

  let entry_addr = MC.segoffAddr $ pblockAddr $ head blocks
  ip_base <- liftIO $ W.natLit symbolicBackend $
    fromIntegral $ MC.addrBase entry_addr
  ip_off <- liftIO $ W.bvLit symbolicBackend W.knownNat $
    MC.memWordToUnsigned $ MC.addrOffset entry_addr
  entry_ip_val <- liftIO $ fromJust <$>
    (MSM.mapRegionPointers memPtrTable) symbolicBackend mem2 ip_base ip_off

  init_regs <- initRegs archVals symbolicBackend entry_ip_val init_sp_val
  some_cfg <- liftIO $ stToIO $ MS.mkBlockPathCFG
    (MS.archFunctions archVals)
    handleAllocator
    Map.empty
    (W.BinaryPos "" . maybe 0 fromIntegral . MC.segoffAsAbsoluteAddr)
    blocks
  case some_cfg of
    C.SomeCFG cfg -> do
      let sim_context = C.initSimContext
            symbolicBackend
            LLVM.llvmIntrinsicTypes
            handleAllocator
            IO.stderr
            C.emptyHandleMap
            extensionImpl
            MS.MacawSimulatorState
      let global_state = C.insertGlobal memVar mem2 C.emptyGlobals
      let simulation = C.regValue <$> C.callCFG cfg init_regs
      let handle_return_type = C.handleReturnType $ C.cfgHandle cfg
      let initial_state = C.InitialState
            sim_context
            global_state
            C.defaultAbortHandler
            (C.runOverrideSim handle_return_type simulation)
      let execution_features = []
      exec_res <- liftIO $ C.executeCrucible execution_features initial_state
      case exec_res of
        C.FinishedResult _ res -> do
          let res_regs = res ^. C.partialValue . C.gpValue
          case C.regValue $ (MS.lookupReg archVals) res_regs MC.ip_reg of
            LLVM.LLVMPointer res_ip_base res_ip_off -> do
              ip_off_ground_vals <- genModels symbolicBackend res_ip_off 10

              ip_base_mem_word <- case MSM.lookupAllocationBase memPtrTable res_ip_base of
                Just alloc -> return $ MSM.allocationBase alloc
                Nothing
                  | Just (W.ConcreteNat 0) <- W.asConcrete res_ip_base ->
                    return $ MC.memWord 0
                  | otherwise ->
                    fail $ "unexpected ip base: " ++ show (W.printSymExpr res_ip_base)

              return $ mapMaybe
                (\off -> MC.resolveAbsoluteAddr (memory discovery_state) $
                  MC.memWord $ fromIntegral $
                    MC.memWordToUnsigned ip_base_mem_word + off)
                ip_off_ground_vals
        C.AbortedResult _ aborted_res -> case aborted_res of
          C.AbortedExec reason _ ->
            fail $ "simulation abort: " ++ show (C.ppAbortExecReason reason)
          C.AbortedExit code ->
            fail $ "simulation halt: " ++ show code
          C.AbortedBranch{} ->
            fail $ "simulation abort branch"
        C.TimeoutResult{} -> fail $ "simulation timeout"

genModels
  :: ( C.IsSymInterface (C.OnlineBackend t solver fp)
     , W.OnlineSolver t solver
     , KnownNat w
     , 1 <= w
     , MonadIO m
     )
  => C.OnlineBackend t solver fp
  -> W.SymBV (C.OnlineBackend t solver fp) w
  -> Int
  -> m [W.GroundValue (W.BaseBVType w)]
genModels sym expr count
  | count > 0 = liftIO $ do
    solver_proc <- C.getSolverProcess sym
    W.checkAndGetModel solver_proc "gen next model" >>= \case
      W.Sat (W.GroundEvalFn{..}) -> do
        next_ground_val <- groundEval expr
        next_bv_val <- W.bvLit sym W.knownNat next_ground_val
        not_current_ground_val <- W.bvNe sym expr next_bv_val
        C.addAssumption sym $ C.LabeledPred not_current_ground_val $
          C.AssumptionReason W.initializationLoc "assume different model"
        more_ground_vals <- genModels sym expr (count - 1)
        return $ next_ground_val : more_ground_vals
      _ -> return []
  | otherwise = return []
