{-# Language GADTs #-}
{-# Language RankNTypes #-}
{-# Language KindSignatures #-}
{-# Language DataKinds #-}
{-# Language TypeApplications #-}
{-# Language TypeFamilies #-}
{-# Language TypeOperators #-}
{-# Language ScopedTypeVariables #-}
{-# Language EmptyCase #-}
{-# Language MultiWayIf #-}
{-# Language PatternGuards #-}
module Data.Macaw.X86.Semantics where

import Data.Parameterized.NatRepr
import Data.Parameterized.Context.Unsafe(empty,extend)

import Data.Bits(shiftR, (.&.))
import Data.Word(Word8)
import Data.Bits(shiftL,testBit)
import GHC.TypeLits(KnownNat)

import           Lang.Crucible.Simulator.ExecutionTree
import           Lang.Crucible.Simulator.RegMap
import qualified Lang.Crucible.Simulator.Evaluation as C
import           Lang.Crucible.Simulator.Intrinsics(IntrinsicTypes)
import           Lang.Crucible.Syntax
import           Lang.Crucible.CFG.Expr
import           Lang.Crucible.Solver.Interface hiding (IsExpr)
import           Lang.Crucible.Types
import qualified Lang.Crucible.Vector as V
import           Lang.Crucible.Utils.Endian(Endian(..))

import qualified Data.Macaw.Types as M
import           Data.Macaw.Symbolic.CrucGen(MacawExt)
import           Data.Macaw.Symbolic
import qualified Data.Macaw.X86 as M
import qualified Data.Macaw.X86.ArchTypes as M


type S sym rtp bs r ctx =
  CrucibleState MacawSimulatorState sym (MacawExt M.X86_64) rtp bs r ctx

semantics ::
  (IsSymInterface sym, ToCrucibleType mt ~ t) =>
  M.X86PrimFn (AtomWrapper (RegEntry sym)) mt ->
  S sym rtp bs r ctx -> IO (RegValue sym t, S sym rtp bs r ctx)
semantics x s = do let sym = Sym { symIface = stateSymInterface s
                                 , symTys   = stateIntrinsicTypes s
                                 , symFuns  = error "XXX: SymFuns"
                                 }
                   v <- pureSem sym x
                   return (v,s)

data Sym s = Sym { symIface :: s
                 , symTys   :: IntrinsicTypes s
                 , symFuns  :: SymFuns s
                 }

data SymFuns s = SymFuns
  { fnAesEnc ::
      SymFn s (EmptyCtx ::> BaseBVType 128 ::> BaseBVType 128) (BaseBVType 128)

  , fnAesEncLast ::
      SymFn s (EmptyCtx ::> BaseBVType 128 ::> BaseBVType 128) (BaseBVType 128)

  , fnClMul ::
      SymFn s (EmptyCtx ::> BaseBVType 64 ::> BaseBVType 64) (BaseBVType 128)
  }


-- | Semantics for operations that do not affect Crucible's state directly.
pureSem :: (IsSymInterface sym) =>
  Sym sym   {- ^ Handle to the simulator -} ->
  M.X86PrimFn (AtomWrapper (RegEntry sym)) mt {- ^ Instruction -} ->
  IO (RegValue sym (ToCrucibleType mt)) -- ^ Resulting value
pureSem sym fn =
  case fn of
    M.EvenParity x ->
      evalE sym  $
       app $ Not $
         foldr1 xor [ bvTestBit (getVal x) i | i <- [ 0 .. 7 ] ]
      where xor a b = app (BoolXor a b)


    M.VOp1 w op1 x ->
      case op1 of
        M.VShiftL n -> vecOp1 sym BigEndian w n8 x
                        (V.shiftL (fromIntegral n) (bv 0))

        M.VShufD mask -> vecOp1 sym LittleEndian w n32 x $ \xs ->
          divExact (V.length xs) n4 $ \i ->
            V.join n4 $ fmap (shuffleD mask)
                      $ V.split i n4 xs

    M.VOp2 w op2 x y ->
      case op2 of
        M.VPOr   -> bitOp2 sym x y (BVOr w)
        M.VPXor  -> bitOp2 sym x y (BVXor w)
        M.VPAnd  -> bitOp2 sym x y (BVAnd w)

        M.VPAlignR s -> vecOp2 sym BigEndian w n8 x y $ \xs ys ->
          divExact (V.length xs) n16 $ \i ->
              V.join n16 $ V.zipWith (vpalign s)
                                     (V.split i n16 xs)
                                     (V.split i n16 ys)

        M.VPShufB -> vecOp2 sym LittleEndian w n8 x y $ \xs ys ->
          divExact (V.length xs) n16 $ \i ->
            V.join n16 $ V.zipWith shuffleB
                                   (V.split i n16 xs)
                                   (V.split i n16 ys)


        M.VPCLMULQDQ i -> unpack2 LittleEndian w n64 x y $ \xs ys ->
          case testEquality (V.length xs) n2 of
            Just Refl ->
              do let v1 = if i `testBit` 0 then V.elemAt n1 xs
                                           else V.elemAt n0 xs
                     v2 = if i `testBit` 4 then V.elemAt n1 ys
                                           else V.elemAt n0 ys

                 x1 <- evalE sym v1
                 x2 <- evalE sym v2
                 let f  = fnClMul (symFuns sym)
                     ps = extend (extend empty x2) x1
                 applySymFn (symIface sym) f ps

            _ -> fail "Unepected size for VPCLMULQDQ"


        M.VAESEnc
          | Just Refl <- testEquality w n128 ->
            do let f      = fnAesEnc (symFuns sym)
                   state  = toVal x
                   key    = toVal y
                   ps     = extend (extend empty state) key
               applySymFn (symIface sym) f ps
          | otherwise -> fail "Unexpecte size for AESEnc"

        M.VAESEncLast
          | Just Refl <- testEquality w n128 ->
            do let f      = fnAesEncLast (symFuns sym)
                   state  = toVal x
                   key    = toVal y
                   ps     = extend (extend empty state) key
               applySymFn (symIface sym) f ps
          | otherwise -> fail "Unexpecte size for AESEncLast"




    M.PointwiseShiftL elNum elSz shSz bits amt ->
      vecOp1 sym LittleEndian (natMultiply elNum elSz) elSz bits $ \xs ->
        fmap (\x -> bvShiftL elSz shSz x (getVal amt)) xs

    M.Pointwise2 elNum elSz op v1 v2 ->
      vecOp2 sym LittleEndian (natMultiply elNum elSz) elSz v1 v2 $ \xs ys ->
        V.zipWith (semPointwise op elSz) xs ys



semPointwise :: (1 <= w) =>
  M.AVXPointWiseOp2 -> NatRepr w ->
    E sym (BVType w) -> E sym (BVType w) -> E sym (BVType w)
semPointwise op w x y =
  case op of
    M.PtAdd -> app (BVAdd w x y)
    M.PtSub -> app (BVSub w x y)

-- | Assumes big-endian split
-- See `vpalign` Intel instruction.
vpalign :: Word8 ->
           V.Vector 16 (E sym (BVType 8)) ->
           V.Vector 16 (E sym (BVType 8)) ->
           V.Vector 16 (E sym (BVType 8))
vpalign i xs ys =
  V.slice n0 n16 (V.shiftR (fromIntegral i) (bv 0) (V.append xs ys))

-- | Shuffling with a mask.
-- See `vpshufd` Intel instruction.
shuffleD :: Word8 -> V.Vector 4 (E sym (BVType 32)) ->
                    V.Vector 4 (E sym (BVType 32))
shuffleD w = V.shuffle getField
  where
  -- Every 2 bits correspond to an index in the input.
  getField x = fromIntegral ((w `shiftR` (2 * x)) .&. 0x03)

-- | See `vpshufb` Intel instruction.
shuffleB :: V.Vector 16 (E sym (BVType 8)) {- ^ Input data -} ->
            V.Vector 16 (E sym (BVType 8)) {- ^ Indexes    -} ->
            V.Vector 16 (E sym (BVType 8))
shuffleB xs is = fmap lkp is
  where
  lkp i = app (BVIte (bvTestBit i 7) knownNat
              (bv 0)
              (bvLookup xs (app $ BVTrunc n4 knownNat i)))

--------------------------------------------------------------------------------
divExact ::
  NatRepr n ->
  NatRepr x ->
  (forall i. ((i * x) ~ n, 1 <= i) => NatRepr i -> k) ->
  k
divExact n x k = withDivModNat n x $ \i r ->
  case testEquality r n0 of
    Just Refl ->
      case testLeq n1 i of
        Just LeqProof -> k i
        Nothing       -> error "divExact: 0 input"
    Nothing -> error "divExact: not a multiple of 16"



vecOp1 :: (IsSymInterface sym, 1 <= c) =>
  Sym sym     {- ^ Simulator -} ->
  Endian      {- ^ How to split-up the bit-vector -} ->
  NatRepr w   {- ^ Total width of the bit-vector -} ->
  NatRepr c   {- ^ Width of individual elements -} ->
  AtomWrapper (RegEntry sym) (M.BVType w) {- ^ The input value -} ->
  (forall n. (1 <= n, (n * c) ~ w) =>
     V.Vector n (E sym (BVType c)) -> V.Vector n (E sym (BVType c))) ->
  -- ^ Definition of operation
  IO (RegValue sym (BVType w)) -- ^ The final result.
vecOp1 sym endian totLen elLen x f =
  unpack endian totLen elLen x $ \v ->
  evalE sym (V.toBV endian elLen (f v))


vecOp2 :: (IsSymInterface sym, 1 <= c) =>
  Sym sym     {- ^ Simulator -} ->
  Endian      {- ^ How to split-up the bit-vector -} ->
  NatRepr w   {- ^ Total width of the bit-vector -} ->
  NatRepr c   {- ^ Width of individual elements -} ->
  AtomWrapper (RegEntry sym) (M.BVType w) {- ^ Input value 1 -} ->
  AtomWrapper (RegEntry sym) (M.BVType w) {- ^ Input value 2 -} ->
  (forall n. (1 <= n, (n * c) ~ w) =>
     V.Vector n (E sym (BVType c)) ->
     V.Vector n (E sym (BVType c)) ->
     V.Vector n (E sym (BVType c))) ->
  -- ^ Definition of operation
  IO (RegValue sym (BVType w)) -- ^ The final result.
vecOp2 sym endian totLen elLen x y f =
  unpack2 endian totLen elLen x y $ \u v ->
  evalE sym (V.toBV endian elLen (f u v))


bitOp2 :: (IsSymInterface sym) =>
  Sym sym                                 {- ^ The simulator -} ->
  AtomWrapper (RegEntry sym) (M.BVType w) {- ^ Input 1 -} ->
  AtomWrapper (RegEntry sym) (M.BVType w) {- ^ Input 2 -} ->
  (E sym (BVType w) -> E sym (BVType w) -> App () (E sym) (BVType w)) ->
                                          -- ^ The definition of the operation
  IO (RegValue sym (BVType w))            {- ^ The result -}
bitOp2 sym x y f = evalE sym $ app $ f (getVal x) (getVal y)

-- | Package-up a vector expression to a bit-vector, and evaluate it.
pack :: (IsSymInterface sym, KnownNat w, 1 <= w) =>
  Endian -> Sym sym ->
  V.Vector n (E sym (BVType w)) -> IO (RegValue sym (BVType (n*w)))
pack e sym xs = evalE sym (V.toBV e knownNat xs)


-- | Split up a bit-vector into a vector.
-- Even though X86 is little endian for memory accesses, this function
-- is parameterized by endianness, as some instructions are more naturally
-- expressed by splitting big-endian-wise (e.g., shifts)
unpack ::
  (1 <= c) =>
  Endian ->
  NatRepr w                               {- ^ Original length -} ->
  NatRepr c                               {- ^ Size of each chunk -} ->
  AtomWrapper (RegEntry sym) (M.BVType w) {- ^ Input value -} ->
  (forall n. (1 <= n, (n * c) ~ w) => V.Vector n (E sym (BVType c)) -> IO a) ->
  IO a
unpack e w c v k = divExact w c $ \n -> k (V.fromBV e n c (getVal v))

-- | Split up two bit-vectors into sub-chunks.
unpack2 ::
  (1 <= c) =>
  Endian ->
  NatRepr w ->
  NatRepr c ->
  AtomWrapper (RegEntry sym) (M.BVType w) ->
  AtomWrapper (RegEntry sym) (M.BVType w) ->
  (forall n. (1 <= n, (n * c) ~ w) =>
      V.Vector n (E sym (BVType c)) ->
      V.Vector n (E sym (BVType c)) ->
      IO a) ->
  IO a
unpack2 e w c v1 v2 k =
  divExact w c $ \n -> k (V.fromBV e n c (getVal v1))
                         (V.fromBV e n c (getVal v2))


getVal :: AtomWrapper (RegEntry sym) mt -> E sym (ToCrucibleType mt)
getVal (AtomWrapper x) = Val x

toVal :: AtomWrapper (RegEntry sym) mt -> RegValue sym (ToCrucibleType mt)
toVal (AtomWrapper x) = regValue x


--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- A small functor that allows mixing of values and Crucible expressions.

evalE :: IsSymInterface sym => Sym sym -> E sym t -> IO (RegValue sym t)
evalE sym e = case e of
                Val x  -> return (regValue x)
                Expr a -> evalApp sym a

evalApp :: forall sym t.  IsSymInterface sym =>
         Sym sym -> App () (E sym) t -> IO (RegValue sym t)
evalApp x = C.evalApp (symIface x) (symTys x) logger evalExt (evalE x)
  where
  logger _ _ = return ()

  evalExt :: fun -> EmptyExprExtension f a -> IO (RegValue sym a)
  evalExt _ y  = case y of {}

data E :: * -> CrucibleType -> * where
  Val  :: RegEntry sym t -> E sym t
  Expr :: App () (E sym) t -> E sym t

instance IsExpr (E sym) where
  type ExprExt (E sym) = ()
  app = Expr
  asApp e = case e of
              Expr a -> Just a
              _      -> Nothing
  exprType e = case e of
                Expr a -> appType a
                Val r  -> regType r


bv :: (KnownNat w, 1 <= w) => Int -> E sym (BVType w)
bv i = app (BVLit knownNat (fromIntegral i))


bvAnd :: (KnownNat w, 1 <= w) =>
  E sym (BVType w) -> E sym (BVType w) -> E sym (BVType w)
bvAnd x y = app (BVAdd knownNat x y)

bvXor :: (KnownNat w, 1 <= w) =>
  E sym (BVType w) -> E sym (BVType w) -> E sym (BVType w)
bvXor x y = app (BVAdd knownNat x y)



bvTestBit :: (KnownNat w, 1 <= w) => E sym (BVType w) -> Int -> E sym BoolType
bvTestBit e n = app $ BVNonzero knownNat $
                app $ BVAnd knownNat e (bv (shiftL 1 n))

bvGetBit :: (KnownNat w, 1 <= w, i + 1 <= w) =>
  E sym (BVType w) -> NatRepr i -> E sym (BVType 1)
bvGetBit e i = app $ BVSelect i n1 knownNat e

bvLookup ::
  (1 <= w, KnownNat w) =>
  V.Vector 16 (E sym (BVType w)) ->
  E sym (BVType 4) ->
  E sym (BVType w)
bvLookup xs ind = ite 0 3
  where
  ite i b = if b < 0
                then V.elemAtUnsafe i xs
                else app $ BVIte (bvTestBit ind b) knownNat
                                 (ite (2 * i + 1) (b - 1))
                                 (ite (2 * i)     (b - 1))

bvShiftL :: (1 <= w, 1 <= i) =>
  NatRepr w -> NatRepr i ->
  E sym (BVType w) -> E sym (BVType i) -> E sym (BVType w)
bvShiftL w i vw vi = app (BVShl w vw amt)
  where amt = case testNatCases i w of
                NatCaseEQ -> vi
                NatCaseLT LeqProof -> app (BVZext w i vi)
                NatCaseGT LeqProof -> app (BVTrunc w i vi)


--------------------------------------------------------------------------------

n0 :: NatRepr 0
n0 = knownNat

n1 :: NatRepr 1
n1 = knownNat

n2 :: NatRepr 2
n2 = knownNat

n4 :: NatRepr 4
n4 = knownNat

n8 :: NatRepr 8
n8 = knownNat

n16 :: NatRepr 16
n16 = knownNat

n32 :: NatRepr 32
n32 = knownNat

n63 :: NatRepr 63
n63 = knownNat

n64 :: NatRepr 64
n64 = knownNat

n128 :: NatRepr 128
n128 = knownNat

--------------------------------------------------------------------------------

newtype AtomWrapper (f :: CrucibleType -> *) (tp :: M.Type)
  = AtomWrapper (f (ToCrucibleType tp))

liftAtomMap :: (forall s. f s -> g s) -> AtomWrapper f t -> AtomWrapper g t
liftAtomMap f (AtomWrapper x) = AtomWrapper (f x)

liftAtomTrav ::
  Functor m =>
  (forall s. f s -> m (g s)) -> (AtomWrapper f t -> m (AtomWrapper g t))
liftAtomTrav f (AtomWrapper x) = AtomWrapper <$> f x

liftAtomIn :: (forall s. f s -> a) -> AtomWrapper f t -> a
liftAtomIn f (AtomWrapper x) = f x


