{-|
Copyright   : (c) Galois Inc, 2016
Maintainer  : jhendrix@galois.com

Operations for creating a view of memory from an elf file.
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
module Data.Macaw.Memory.ElfLoader
  ( SectionIndexMap
  , memoryForElf
  , resolveElfFuncSymbols
  , initElfDiscoveryInfo
  , elfAddrWidth
  , module Data.Macaw.Memory.LoadCommon
  ) where

import           Control.Lens
import           Control.Monad.Except
import           Control.Monad.State.Strict
import           Data.Bits
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as L
import           Data.Either
import           Data.ElfEdit
  ( ElfIntType
  , ElfWordType

  , Elf
  , elfSections
  , elfLayout

  , ElfClass(..)
  , elfClass

  , ElfSection
  , ElfSectionIndex(..)
  , elfSectionIndex
  , ElfSectionFlags
  , elfSectionFlags
  , elfSectionName
  , elfSectionFileSize
  , elfSectionAddr
  , elfSectionData

  , elfSegmentIndex
  , elfSegmentVirtAddr
  , ElfSegmentFlags
  , elfSegmentFlags
  , elfLayoutBytes

  , ElfSymbolTableEntry
  )
import qualified Data.ElfEdit as Elf
import           Data.Foldable
import           Data.Int (Int64)
import           Data.IntervalMap.Strict (Interval(..), IntervalMap)
import qualified Data.IntervalMap.Strict as IMap
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe
import qualified Data.Vector as V
import           Numeric (showHex)

import           Data.Macaw.Memory
import           Data.Macaw.Memory.LoadCommon
import qualified Data.Macaw.Memory.Permissions as Perm

-- | Return a subbrange of a bytestring.
sliceL :: Integral w => Elf.Range w -> L.ByteString -> L.ByteString
sliceL (i,c) = L.take (fromIntegral c) . L.drop (fromIntegral i)

-- | Return the addr width repr associated with an elf class
elfAddrWidth :: ElfClass w -> AddrWidthRepr w
elfAddrWidth ELFCLASS32 = Addr32
elfAddrWidth ELFCLASS64 = Addr64

------------------------------------------------------------------------
-- SectionIndexMap

-- | Maps section indices that are loaded in memory to their associated base
-- address and section contents.
--
-- The base address is expressed in terms of the underlying memory segment.
type SectionIndexMap w = Map ElfSectionIndex (MemSegmentOff w, ElfSection (ElfWordType w))

------------------------------------------------------------------------
-- Flag conversion

-- | Create Reopt flags from elf flags.
flagsForSegmentFlags :: ElfSegmentFlags -> Perm.Flags
flagsForSegmentFlags f
    =   flagIf Elf.pf_r Perm.read
    .|. flagIf Elf.pf_w Perm.write
    .|. flagIf Elf.pf_x Perm.execute
  where flagIf :: ElfSegmentFlags -> Perm.Flags -> Perm.Flags
        flagIf ef pf | f `Elf.hasPermissions` ef = pf
                     | otherwise = Perm.none

-- | Convert elf section flags to a segment flags.
flagsForSectionFlags :: forall w
                     .  (Num w, Bits w)
                     => ElfSectionFlags w
                     -> Perm.Flags
flagsForSectionFlags f =
    Perm.read .|. flagIf Elf.shf_write Perm.write .|. flagIf Elf.shf_execinstr Perm.execute
  where flagIf :: ElfSectionFlags w -> Perm.Flags -> Perm.Flags
        flagIf ef pf = if f `Elf.hasPermissions` ef then pf else Perm.none

------------------------------------------------------------------------
-- RegionAdjust

-- | This captures how to translate addresses in the Elf file to
-- regions in the memory object.
data RegionAdjust
  = RegionAdjust { regionIndex :: !RegionIndex
                   -- ^ Region index for new segments
                 , regionOffset :: !Integer
                   -- ^ Offset from region to automatically add to
                   -- segment/sections during loading.
                 }

------------------------------------------------------------------------
-- Loading by segment

-- | Convert bytes into a segment range list.
singleSegment :: L.ByteString -> [SegmentRange w]
singleSegment contents | L.null contents = []
                       | otherwise = [ByteRegion (L.toStrict contents)]

-- | @bssSegment cnt@ creates a BSS region with size @cnt@.
bssSegment :: MemWidth w => Int64 -> [SegmentRange w]
bssSegment c | c <= 0 = []
             | otherwise = [BSSRegion (fromIntegral c)]

-- | Contents of segment/section before symbol folded in.
data PresymbolData = PresymbolData !L.ByteString !Int64

mkPresymbolData :: L.ByteString -> Int64 -> PresymbolData
mkPresymbolData contents0 sz
  | sz >= L.length contents0 = PresymbolData contents0 (sz - L.length contents0)
  | otherwise = PresymbolData (L.take sz contents0) 0

allSymbolData :: MemWidth w => PresymbolData -> [SegmentRange w]
allSymbolData (PresymbolData contents bssSize) =
  singleSegment contents ++ bssSegment bssSize

-- | Take the given amount of data out of presymbol data.
takeSegment :: MemWidth w => Int64 -> PresymbolData -> [SegmentRange w]
takeSegment cnt (PresymbolData contents bssSize) =
  singleSegment (L.take cnt contents)
  ++ bssSegment (min (cnt - L.length contents) bssSize)

-- | @dropSegment cnt dta@ drops @cnt@ bytes from @dta@.
dropSegment :: Int64 -> PresymbolData -> PresymbolData
dropSegment cnt (PresymbolData contents bssSize)
  | cnt <= L.length contents = PresymbolData (L.drop cnt contents) bssSize
  | otherwise = PresymbolData L.empty (bssSize - (cnt - L.length contents))

-- | This takes a list of symbols and an address and coerces into a memory contents.
--
-- If the size is different from the length of file contents, then the file content
-- buffer is truncated or zero-extended as in a BSS.
byteSegments :: forall w
             .  MemWidth w
             => RelocMap (MemWord w) -- ^ Map from addresses to symbolis
             -> MemWord w -- ^ Base address for segment
             -> L.ByteString -- ^ File contents for segment.
             -> Int64 -- ^ Expected size
             -> [SegmentRange w]
byteSegments allSymbols initBase contents0 sz =
    bytesToSegmentsAscending symbolPairs initBase (mkPresymbolData contents0 sz)
  where -- Parse the map to get a list of symbols starting at base0.
        symbolPairs
          = Map.toList
          $ Map.dropWhileAntitone (< initBase) allSymbols

        -- Get last address for this region
        end :: MemWord w
        end = initBase + fromIntegral sz

        -- Get size of pointer
        ptrSize :: MemWord w
        ptrSize = fromIntegral (addrSize initBase)

        -- Traverse the list of symbols that we should parse.
        bytesToSegmentsAscending ::[(MemWord w, SymbolRef)] -- ^ List of symbols within the segment.
                                 -> MemWord w -- ^ The starting address of memory
                                 -> PresymbolData
                                  -- ^ The remaining bytes in memory including a number extra bss.
                                 -> [SegmentRange w]
        bytesToSegmentsAscending ((addr,tgt):rest) base contents | addr < end =
            takeSegment (fromIntegral off) contents
            ++ [SymbolicRef tgt]
            ++ bytesToSegmentsAscending rest (addr + ptrSize) post
          where off = addr - base
                post   = dropSegment (fromIntegral (off + ptrSize)) contents
        bytesToSegmentsAscending _ _ contents = allSymbolData contents

-- | Return a memory segment for elf segment if it loadable.
memSegmentForElfSegment :: (MemWidth w, Integral (ElfWordType w))
                        => RegionAdjust -- ^ Index for segment
                        -> L.ByteString
                           -- ^ Complete contents of Elf file.
                        -> RelocMap (MemWord w)
                           -- ^ Relocation map
                        -> Elf.Phdr w
                           -- ^ Program header entry
                        -> Maybe (MemSegment w)
memSegmentForElfSegment regAdj contents relocMap phdr = memSegment (regionIndex regAdj) base flags segContents
  where seg = Elf.phdrSegment phdr
        dta = sliceL (Elf.phdrFileRange phdr) contents
        sz = fromIntegral $ Elf.phdrMemSize phdr
        base = regionOffset regAdj + toInteger (elfSegmentVirtAddr seg)
        flags = flagsForSegmentFlags (elfSegmentFlags seg)
        segContents = byteSegments relocMap (fromInteger base) dta sz

-- | Create memory segment from elf section.
--
-- This returns `Nothing` if the memory segment is empty.
-- TODO: Evaluate whether we should do the same for memSegmentForElfSegment, and
-- whether we should add relocations.
memSegmentForElfSection :: (Integral v, Bits v, MemWidth w)
                        => RegionIndex -- ^ Index for segment
                        -> RelocMap (MemWord w)
                        -> ElfSection v
                        -> Maybe (MemSegment w)
memSegmentForElfSection regIdx relocMap s =
    memSegment regIdx (toInteger base) flags fixedData
  where base = elfSectionAddr s
        flags = flagsForSectionFlags (elfSectionFlags s)
        bytes = elfSectionData s
        dta = L.fromStrict bytes
        sz = fromIntegral (Elf.elfSectionSize s)
        fixedData = byteSegments relocMap (fromIntegral base) dta sz

------------------------------------------------------------------------
-- MemLoader

data MemLoaderState w = MLS { mlsRegionAdjust :: !RegionAdjust
                            , _mlsMemory :: !(Memory w)
                            , _mlsIndexMap :: !(SectionIndexMap w)
                            }

mlsMemory :: Simple Lens (MemLoaderState w) (Memory w)
mlsMemory = lens _mlsMemory (\s v -> s { _mlsMemory = v })

-- | Map from elf section indices to their offset and section
mlsIndexMap :: Simple Lens (MemLoaderState w) (SectionIndexMap w)
mlsIndexMap = lens _mlsIndexMap (\s v -> s { _mlsIndexMap = v })

memLoaderPair :: MemLoaderState w -> (SectionIndexMap w, Memory w)
memLoaderPair mls = (mls^.mlsIndexMap, mls^.mlsMemory)

type MemLoader w = StateT (MemLoaderState w) (Except String)

runMemLoader :: RegionAdjust -> Memory  w -> MemLoader w () -> Either String (SectionIndexMap w, Memory w)
runMemLoader regAdj mem m = fmap memLoaderPair $ runExcept $ execStateT m s
   where s = MLS { mlsRegionAdjust = regAdj
                 , _mlsMemory = mem
                 , _mlsIndexMap = Map.empty
                 }


-- | This adds a Macaw mem segment to the memory
loadMemSegment :: MemWidth w => String -> MemSegment w -> MemLoader w ()
loadMemSegment nm seg =
  StateT $ \mls -> do
    case insertMemSegment seg (mls^.mlsMemory) of
      Left (OverlapSegment _ old) ->
        throwError $ nm ++ " overlaps with memory segment: " ++ show (segmentOffset old)
      Right mem' -> do
        pure ((), mls & mlsMemory .~ mem')

-- | Maps file offsets to the elf section
type ElfFileSectionMap v = IntervalMap v (ElfSection v)

------------------------------------------------------------------------
-- Symbol information.

-- | Ma an Elf version id to
mkSymbolVersion :: Elf.VersionId -> SymbolVersion
mkSymbolVersion ver = SymbolVersion { symbolVersionFile = Elf.verFile ver
                                    , symbolVersionName = Elf.verName ver
                                    }

mkSymbolRef :: Elf.VersionedSymbol tp -> SymbolRef
mkSymbolRef (sym, mverId) =
  SymbolRef { symbolName = Elf.steName sym
            , symbolVisibility =
                case mverId of
                  Elf.VersionLocal -> LocalSymbol
                  Elf.VersionGlobal -> GlobalSymbol
                  Elf.VersionSpecific verId -> VersionedSymbol (mkSymbolVersion verId)
            }

------------------------------------------------------------------------
-- RelocMap

-- | Maps an address to the symbol that it is associated for.
type RelocMap w = Map w SymbolRef

checkZeroAddend :: ( Eq (ElfIntType (Elf.RelocationWidth tp))
                   , Num (ElfIntType (Elf.RelocationWidth tp))
                   )
                => Elf.RelaEntry tp
                -> Either String ()
checkZeroAddend rel =
  when (Elf.r_addend rel /= 0) $ Left "Cannot relocate symbols with non-zero addend."

relaSymbol  :: V.Vector v -> Elf.RelaEntry tp -> Either String v
relaSymbol symtab rel =
  case symtab V.!? fromIntegral (Elf.r_sym rel) of
    Nothing -> Left $ "Could not find symbol at index " ++ show (Elf.r_sym rel) ++ "."
    Just sym -> Right sym

-- | Creates a map that forwards addresses to be relocated to their appropriate target.
type RelaTargetFn tp = V.Vector SymbolRef -> Elf.RelaEntry tp -> Either String (Maybe SymbolRef)

-- | Given a relocation entry, this returns either @Left msg@ if the relocation
-- cannot be resolved, @Right Nothing@ if
relaTargetX86_64 :: RelaTargetFn Elf.X86_64_RelocationType
relaTargetX86_64 symtab rel =
  case Elf.r_type rel of
    Elf.R_X86_64_GLOB_DAT -> do
      checkZeroAddend rel
      Just <$> relaSymbol symtab rel
    Elf.R_X86_64_COPY -> Right Nothing
    Elf.R_X86_64_JUMP_SLOT -> do
      checkZeroAddend rel
      Just <$> relaSymbol symtab rel
    tp -> Left $ "Do not yet support relocation type: " ++ show tp

relaTargetARM :: RelaTargetFn Elf.ARM_RelocationType
relaTargetARM symtab rel =
  case Elf.r_type rel of
    Elf.R_ARM_GLOB_DAT -> do
      checkZeroAddend rel
      Just <$> relaSymbol symtab rel
    Elf.R_ARM_COPY -> Right Nothing
    Elf.R_ARM_JUMP_SLOT -> do
      checkZeroAddend rel
      Just <$> relaSymbol symtab rel
    tp -> Left $ "Do not yet support relocation type: " ++ show tp

--(Elf.IsRelocationType tp, MemWidth (Elf.RelocationWidth tp), Integral (Elf.RelocationWord tp))
--           =>
-- | Creates a map that forwards addresses to be relocated to their appropriate target.
relocEntry :: (MemWidth (Elf.RelocationWidth tp), Integral (Elf.RelocationWord tp))
           => RelaTargetFn tp
           -> V.Vector SymbolRef
           -> Elf.RelaEntry tp
           -> Either String (Maybe (MemWord (Elf.RelocationWidth tp), SymbolRef))
relocEntry relaTarget symtab rel = fmap (fmap f) $ relaTarget symtab rel
  where f tgt = (memWord (fromIntegral (Elf.r_offset rel)), tgt)

-- Given a list returns a map mapping keys to their associated values, or
-- a key that appears in multiple elements.
mapFromListUnique :: Ord k => [(k,v)] -> Either k (Map k v)
mapFromListUnique = foldlM f Map.empty
  where f m (k,v) =
          case Map.lookup k m of
            Nothing -> Right $! Map.insert k v m
            Just _ -> Left k

-- | Creates a map that forwards addresses to be relocated to their appropriate target.
mkRelocMap :: ( Elf.IsRelocationType tp
              , MemWidth (Elf.RelocationWidth tp)
              , Integral (Elf.RelocationWord  tp)
              )
           => RelaTargetFn tp
           -> V.Vector SymbolRef
           -> [Elf.RelaEntry tp]
           -> Either String (RelocMap (MemWord (Elf.RelocationWidth tp)))
mkRelocMap relaTarget symtab l = do
  mentries <- traverse (relocEntry relaTarget symtab) l
  let errMsg w = show w ++ " appears in multiple relocations."
  case mapFromListUnique $ catMaybes mentries of
    Left dup -> Left (errMsg dup)
    Right v -> Right v

-- | Creates a relocation map from the contents of a dynamic section.
relocMapOfDynamic :: forall w
                  .  (MemWidth w, Integral (ElfWordType w))
                  => Elf.ElfHeader w
                  -> Elf.VirtAddrMap w
                  -> L.ByteString -- ^ Contents of .dynamic section
                  -> MemLoader w (RelocMap (MemWord w))
relocMapOfDynamic hdr virtMap dynContents =
  case (Elf.headerClass hdr, Elf.headerMachine hdr) of
    (Elf.ELFCLASS64, Elf.EM_X86_64) -> go relaTargetX86_64
    (Elf.ELFCLASS32, Elf.EM_ARM)    -> go relaTargetARM
    (_,mach) -> throwError $ "Dynamic libraries are not supported on " ++ show mach ++ "."
  where go :: forall tp
           .  (Elf.IsRelocationType tp, w ~ Elf.RelocationWidth tp)
           => RelaTargetFn tp
           -> MemLoader (Elf.RelocationWidth tp) (RelocMap (MemWord (Elf.RelocationWidth tp)))
        go relaTarget = do
          dynSection <- either (throwError . show) pure $
            Elf.dynamicEntries (Elf.headerData hdr) (Elf.headerClass hdr) virtMap dynContents
          relocs <- either (throwError . show) pure $
            Elf.dynRelocations dynSection
          syms <- either (throwError . show) pure $
            Elf.dynSymTable dynSection
          either throwError pure $
            mkRelocMap relaTarget (mkSymbolRef <$> syms) relocs

------------------------------------------------------------------------
-- Elf segment loading

reprConstraints :: AddrWidthRepr w
                -> ((Bits (ElfWordType w), Integral (ElfWordType w), Show (ElfWordType w), MemWidth w) => a)
                -> a
reprConstraints Addr32 x = x
reprConstraints Addr64 x = x

-- | Load an elf file into memory.
insertElfSegment :: ElfFileSectionMap (ElfWordType w)
                 -> L.ByteString
                 -> RelocMap (MemWord w)
                    -- ^ Relocations to apply in loading section.
                 -> Elf.Phdr w
                 -> MemLoader w ()
insertElfSegment shdrMap contents relocMap phdr = do
  regAdj <- gets mlsRegionAdjust
  w <- uses mlsMemory memAddrWidth
  reprConstraints w $ do
  case memSegmentForElfSegment regAdj contents relocMap phdr of
    Nothing -> pure ()
    Just seg -> do
      let seg_idx = elfSegmentIndex (Elf.phdrSegment phdr)
      loadMemSegment ("Segment " ++ show seg_idx) seg
      let phdr_offset = Elf.fromFileOffset (Elf.phdrFileStart phdr)
      let phdr_end = phdr_offset + Elf.phdrFileSize phdr
      let l = IMap.toList $ IMap.intersecting shdrMap (IntervalCO phdr_offset phdr_end)
      forM_ l $ \(i, sec) -> do
        case i of
          IntervalCO shdr_start _ -> do
            let elfIdx = ElfSectionIndex (elfSectionIndex sec)
            when (phdr_offset > shdr_start) $ do
              fail $ "Found section header that overlaps with program header."
            let sec_offset = fromIntegral $ shdr_start - phdr_offset
            let Just addr = resolveSegmentOff seg sec_offset
            mlsIndexMap %= Map.insert elfIdx (addr, sec)
          _ -> fail "Unexpected shdr interval"

-- | Load an elf file into memory with the given options.
memoryForElfSegments
  :: forall w
  .  Elf  w
  -> MemLoader w ()
memoryForElfSegments e = do
  let l = elfLayout e
  let w = elfAddrWidth (elfClass e)
  reprConstraints w $ do
  let ph  = Elf.allPhdrs l
  let contents = elfLayoutBytes l
  virtMap <- maybe (throwError "Overlapping loaded segments") pure $
    Elf.virtAddrMap contents ph
  relocMap <-
    case filter (Elf.hasSegmentType Elf.PT_DYNAMIC . Elf.phdrSegment) ph of
      [] -> pure Map.empty
      [dynPhdr] -> do
        let dynContents = sliceL (Elf.phdrFileRange dynPhdr) contents
        relocMapOfDynamic (Elf.elfHeader e) virtMap dynContents
      _ -> throwError "Multiple dynamic sections"

  let intervals :: ElfFileSectionMap (ElfWordType w)
      intervals = IMap.fromList $
          [ (IntervalCO start end, sec)
          | shdr <- Map.elems (l ^. Elf.shdrs)
          , let start = shdr^._3
          , let sec = shdr^._1
          , let end = start + elfSectionFileSize sec
          ]
  mapM_ (insertElfSegment intervals contents relocMap)
        (filter (Elf.hasSegmentType Elf.PT_LOAD . Elf.phdrSegment) ph)

------------------------------------------------------------------------
-- Elf section loading

-- | Load an elf file into memory.
insertElfSection :: RelocMap (MemWord w)
                    -- ^ Relocations to apply in loading section.
                 -> ElfSection (ElfWordType w)
                 -> MemLoader w ()
insertElfSection relocMap sec = do
  regAdj <- mlsRegionAdjust <$> get
  w <- uses mlsMemory memAddrWidth
  reprConstraints w $ do
  -- Check if we should load section
  let doLoad = elfSectionFlags sec `Elf.hasPermissions` Elf.shf_alloc
            && elfSectionName sec /= ".eh_frame"
  let regIdx = regionIndex regAdj
  case memSegmentForElfSection regIdx relocMap sec of
    Just seg | doLoad -> do
      loadMemSegment ("Section " ++ BSC.unpack (elfSectionName sec) ++ " " ++ show (Elf.elfSectionSize sec)) seg
      let elfIdx = ElfSectionIndex (elfSectionIndex sec)
      let Just addr = resolveSegmentOff seg 0
      mlsIndexMap %= Map.insert elfIdx (addr, sec)
    _ -> pure ()

-- | Load allocated Elf sections into memory.
--
-- Normally, Elf uses segments for loading, but the segment
-- information tends to be more precise.
--
-- TODO: Populate relocation map
memoryForElfSections :: Elf w
                     -> MemLoader w ()
memoryForElfSections e = do
  traverseOf_ elfSections (insertElfSection Map.empty) e

------------------------------------------------------------------------
-- High level loading

-- | Return true if Elf has a @PT_DYNAMIC@ segment (thus indicating it
-- is relocatable.
isRelocatable :: Elf w -> Bool
isRelocatable e = any (Elf.hasSegmentType Elf.PT_DYNAMIC) (Elf.elfSegments e)

adjustedLoadRegionIndex :: Elf w -> LoadOptions -> RegionIndex
adjustedLoadRegionIndex e loadOpt =
  case loadRegionIndex loadOpt of
    Just idx -> idx
    Nothing ->
      case Elf.elfType e of
        Elf.ET_REL -> 1
        Elf.ET_EXEC -> if isRelocatable e then 1 else 0
        Elf.ET_DYN -> 1
        _ -> 0

adjustedLoadStyle :: Elf w -> LoadOptions -> LoadStyle
adjustedLoadStyle e loadOpt =
  case loadStyleOverride loadOpt of
    Just sty -> sty
    Nothing ->
      case Elf.elfType e of
        Elf.ET_REL -> LoadBySection
        _ -> LoadBySegment

-- | Load allocated Elf sections into memory.
--
-- Normally, Elf uses segments for loading, but the segment
-- information tends to be more precise.
memoryForElf :: LoadOptions
             -> Elf w
             -> Either String (SectionIndexMap w, Memory w)
memoryForElf opt e = do
  let regAdj = RegionAdjust { regionIndex  = adjustedLoadRegionIndex e opt
                            , regionOffset = loadRegionBaseOffset opt
                            }
  runMemLoader regAdj (emptyMemory (elfAddrWidth (elfClass e))) $ do
    case adjustedLoadStyle e opt of
      LoadBySection -> memoryForElfSections e
      LoadBySegment -> memoryForElfSegments e

------------------------------------------------------------------------
-- Elf symbol utilities

-- | Error when resolving symbols.
data SymbolResolutionError
   = EmptySymbolName !Int !Elf.ElfSymbolType
     -- ^ Symbol names must be non-empty
   | CouldNotResolveAddr !BSC.ByteString
     -- ^ Symbol address could not be resolved.
   | MultipleSymbolTables
     -- ^ The elf file contained multiple symbol tables

instance Show SymbolResolutionError where
  show (EmptySymbolName idx tp ) = "Symbol Num " ++ show idx ++ " " ++ show tp ++ " has an empty name."
  show (CouldNotResolveAddr sym) = "Could not resolve address of " ++ BSC.unpack sym ++ "."
  show MultipleSymbolTables = "Elf contains multiple symbol tables."

-- | This resolves an Elf symbol into a MemSymbol if it is likely a
-- pointer to a resolved function.
resolveElfFuncSymbol :: Memory w -- ^ Memory object from Elf file.
                     -> SectionIndexMap w -- ^ Section index mp from memory
                     -> Int -- ^ Index of symbol
                     -> ElfSymbolTableEntry (ElfWordType w)
                     -> Maybe (Either SymbolResolutionError (MemSymbol w))
resolveElfFuncSymbol mem secMap idx ste
  -- Check this is a defined function symbol
  -- Some NO_TYPE entries appear to correspond to functions, so we include those.
  | (Elf.steType ste `elem` [ Elf.STT_FUNC, Elf.STT_NOTYPE ]) == False =
    Nothing
    -- Check symbol is defined
  | Elf.steIndex ste == Elf.SHN_UNDEF = Nothing
  -- Check symbol name is non-empty
  | Elf.steName ste == "" = Just $ Left $ EmptySymbolName idx (Elf.steType ste)
  -- Lookup absolute symbol
  | Elf.steIndex ste == Elf.SHN_ABS = reprConstraints (memAddrWidth mem) $ do
      let val = Elf.steValue ste
      case resolveAddr mem 0 (fromIntegral val) of
        Just addr -> Just $ Right $
                     MemSymbol { memSymbolName = Elf.steName ste
                               , memSymbolStart = addr
                               , memSymbolSize = fromIntegral (Elf.steSize ste)
                               }
        Nothing   -> Just $ Left $ CouldNotResolveAddr (Elf.steName ste)
  -- Lookup symbol stored in specific section
  | otherwise = reprConstraints (memAddrWidth mem) $ do
      let val = Elf.steValue ste
      case Map.lookup (Elf.steIndex ste) secMap of
        Just (base,sec)
          | elfSectionAddr sec <= val && val < elfSectionAddr sec + Elf.elfSectionSize sec
          , off <- toInteger val - toInteger (elfSectionAddr sec)
          , Just addr <- incSegmentOff base off -> do
              Just $ Right $ MemSymbol { memSymbolName = Elf.steName ste
                                       , memSymbolStart = addr
                                       , memSymbolSize = fromIntegral (Elf.steSize ste)
                                       }
        _ -> Just $ Left $ CouldNotResolveAddr (Elf.steName ste)

-- | Resolve symbol table entries to the addresses in a memory.
--
-- It takes the memory constructed from the Elf file, the section
-- index map, and the symbol table entries.  It returns unresolvable
-- symbols and the map from segment offsets to bytestring.
resolveElfFuncSymbols
  :: forall w
  .  Memory w
  -> SectionIndexMap w
  -> Elf w
  -> ([SymbolResolutionError], [MemSymbol w])
resolveElfFuncSymbols mem secMap e =
  case Elf.elfSymtab e of
    [] -> ([], [])
    [tbl] ->
      let entries = V.toList (Elf.elfSymbolTableEntries tbl)
       in partitionEithers (mapMaybe (uncurry (resolveElfFuncSymbol mem secMap)) (zip [0..] entries))
    _ -> ([MultipleSymbolTables], [])

------------------------------------------------------------------------
-- initElfDiscoveryInfo

-- | Return the segment offset of the elf file entry point or fail if undefined.
getElfEntry ::  LoadOptions -> Memory w -> Elf w -> ([String], Maybe (MemSegmentOff w))
getElfEntry loadOpts mem e =  addrWidthClass (memAddrWidth mem) $ do
 Elf.elfClassInstances (Elf.elfClass e) $ do
   let regIdx = adjustedLoadRegionIndex e loadOpts
   let adjAddr = loadRegionBaseOffset loadOpts + toInteger (Elf.elfEntry e)
   case resolveAddr mem regIdx (fromInteger adjAddr) of
     Nothing ->
       ( ["Could not resolve entry point: " ++ showHex (Elf.elfEntry e) ""]
       , Nothing
       )
     Just v  -> ([], Just v)

-- | This interprets the Elf file to construct the initial memory,
-- entry points, and functions symbols.
--
-- If it encounters a fatal error it returns the error message in the left value,
-- and otherwise it returns the information interred as a 4-tuple.
initElfDiscoveryInfo :: LoadOptions
                        -- ^ Options for loading contents
                     -> Elf w -- ^ Elf file to create memory
                     -> Either String
                           ( [String] -- Warnings
                           , Memory w -- Initial memory
                           , Maybe (MemSegmentOff w) -- Entry point(s)
                           , [MemSymbol w] -- Function symbols
                           )
initElfDiscoveryInfo loadOpts e = do
  case Elf.elfType e of
    Elf.ET_REL -> do
      case loadStyleOverride loadOpts of
        Just LoadBySegment -> do
          Left $ "Cannot load object files by segment."
        _ -> pure ()
      (secMap, mem) <- memoryForElf loadOpts e
      let (symErrs, funcSymbols) = resolveElfFuncSymbols mem secMap e
      pure (show <$> symErrs, mem, Nothing, funcSymbols)
    Elf.ET_EXEC -> do
      (secMap, mem) <- memoryForElf loadOpts e
      let (entryWarn, mentry) = getElfEntry loadOpts mem e
      let (symErrs, funcSymbols) = resolveElfFuncSymbols mem secMap e
      Right (entryWarn ++ fmap show symErrs, mem, mentry, funcSymbols)
    Elf.ET_DYN -> do
      (secMap, mem) <- memoryForElf loadOpts e
      let (entryWarn, mentry) = getElfEntry loadOpts mem e
      let (symErrs, funcSymbols) = resolveElfFuncSymbols mem secMap e
      pure (entryWarn ++ fmap show symErrs, mem, mentry, funcSymbols)
    Elf.ET_CORE -> do
      Left $ "Reopt does not support loading core files."
    tp -> do
      Left $ "Reopt does not support loading elf files with type " ++ show tp ++ "."
