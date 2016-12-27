{-|
Module      : Data.Macaw.Memory.ElfLoader
Copyright   : (c) Galois Inc, 2016
Maintainer  : jhendrix@galois.com

Operations for creating a view of memory from an elf file.
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Data.Macaw.Memory.ElfLoader
  ( SectionIndexMap
  , memoryForElfSegments
  , memoryForElfSections
    -- * High-level exports
  , readElf
  , loadExecutable
  , loadElfBySection
  ) where

import           Control.Lens
import           Control.Monad.Except
import           Control.Monad.State.Strict
import           Data.Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as L
import           Data.ElfEdit
import           Data.Foldable
import           Data.IntervalMap.Strict (Interval(..), IntervalMap)
import qualified Data.IntervalMap.Strict as IMap
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Parameterized.NatRepr
import qualified Data.Vector as V
import           System.IO

import           Data.Macaw.Memory
import qualified Data.Macaw.Memory.Permissions as Perm

-- | Return a subbrange of a bytestring.
sliceL :: Integral w => Range w -> L.ByteString -> L.ByteString
sliceL (i,c) = L.take (fromIntegral c) . L.drop (fromIntegral i)

------------------------------------------------------------------------
-- SectionIndexMap

-- | Maps section indices that are loaded in memory to their associated base
-- address and section contents.
--
-- The base address is expressed in terms of the underlying memory segment.
type SectionIndexMap v w = Map ElfSectionIndex (SegmentedAddr w, ElfSection v)

------------------------------------------------------------------------
-- Flag conversion

-- | Create Reopt flags from elf flags.
flagsForSegmentFlags :: ElfSegmentFlags -> Perm.Flags
flagsForSegmentFlags f
    =   flagIf pf_r Perm.read
    .|. flagIf pf_w Perm.write
    .|. flagIf pf_x Perm.execute
  where flagIf :: ElfSegmentFlags -> Perm.Flags -> Perm.Flags
        flagIf ef pf | f `hasPermissions` ef = pf
                     | otherwise = Perm.none

-- | Convert elf section flags to a segment flags.
flagsForSectionFlags :: forall w
                     .  (Num w, Bits w)
                     => ElfSectionFlags w
                     -> Perm.Flags
flagsForSectionFlags f =
    Perm.read .|. flagIf shf_write Perm.write .|. flagIf shf_execinstr Perm.execute
  where flagIf :: ElfSectionFlags w -> Perm.Flags -> Perm.Flags
        flagIf ef pf = if f `hasPermissions` ef then pf else Perm.none

------------------------------------------------------------------------
-- MemSegment

-- | Return segments for data
byteSegments :: forall w
             .  MemWidth w
             => RelocMap (MemWord w)
             -> MemWord w -- ^ Base address for segment
             -> L.ByteString
             -> [SegmentRange w]
byteSegments m0 base0 contents0 = go base0 (Map.toList m) contents0
  where end = base0 + fromIntegral (L.length contents0)
        -- Get only those elements in m between [base0, end)
        m = Map.takeWhileAntitone (< end)
          $ Map.dropWhileAntitone (< base0) m0
        -- Get size of address
        ptrSize :: MemWord w
        ptrSize = addrSize base0
        -- Return segment range for contents.
        singleSegment :: L.ByteString -> [SegmentRange w]
        singleSegment contents | L.null contents = []
                               | otherwise = [ByteRegion (L.toStrict contents)]
        -- Create segments
        go :: MemWord w -> [(MemWord w, SymbolRef)] -> L.ByteString -> [SegmentRange w]
        go _ [] contents = singleSegment contents
        go base ((addr,tgt):rest) contents =
            preseg ++ [SymbolicRef tgt] ++ go (addr + ptrSize) rest post
          where off = addr - base
                preseg = singleSegment (L.take (fromIntegral off) contents)
                post   = L.drop (fromIntegral (off + ptrSize)) contents

-- | Return a memory segment for elf segment if it loadable.
memSegmentForElfSegment :: (Integral v, MemWidth w)
                        => SegmentIndex
                        -> L.ByteString
                           -- ^ Complete contents of Elf file.
                        -> RelocMap (MemWord w)
                           -- ^ Relocaction map
                        -> Phdr v
                           -- ^ Program header entry
                        -> MemSegment w
memSegmentForElfSegment idx contents relocMap phdr = mseg
  where seg = phdrSegment phdr
        dta = sliceL (phdrFileRange phdr) contents
        sz = fromIntegral $ phdrMemSize phdr
        fixedData
          | L.length dta > sz = L.take sz dta
          | otherwise = dta `mappend` L.replicate (sz - L.length dta) 0
        addr = fromIntegral $ elfSegmentVirtAddr seg
        flags = flagsForSegmentFlags (elfSegmentFlags seg)
        mseg = memSegment idx (Just addr) flags (byteSegments relocMap addr fixedData)

-- | Create memory segment from elf section.
memSegmentForElfSection :: (Integral v, Bits v, MemWidth w)
                        => SegmentIndex
                        -> ElfSection v
                        -> MemSegment w
memSegmentForElfSection idx s = mseg
  where mseg = memSegment idx (Just base) flags [ByteRegion bytes]
        base = fromIntegral (elfSectionAddr s)
        flags = flagsForSectionFlags (elfSectionFlags s)
        bytes = elfSectionData s

------------------------------------------------------------------------
-- MemLoader

data MemLoaderState v w = MLS { _mlsIndex :: !SegmentIndex
                              , _mlsMemory :: !(Memory w)
                              , _mlsIndexMap :: !(SectionIndexMap v w)
                              }

mlsIndex :: Simple Lens (MemLoaderState v w) SegmentIndex
mlsIndex = lens _mlsIndex (\s v -> s { _mlsIndex = v })

mlsMemory :: Simple Lens (MemLoaderState v w) (Memory w)
mlsMemory = lens _mlsMemory (\s v -> s { _mlsMemory = v })

mlsIndexMap :: Simple Lens (MemLoaderState v w) (SectionIndexMap v w)
mlsIndexMap = lens _mlsIndexMap (\s v -> s { _mlsIndexMap = v })

initState :: forall w . RelaWidth w -> MemLoaderState (ElfWordType w) w
initState rw = MLS { _mlsIndex = 0
                   , _mlsMemory = emptyMemory w
                   , _mlsIndexMap = Map.empty
                   }
  where w :: NatRepr w
        w = case rw of
              Rela32 -> knownNat
              Rela64 -> knownNat

memLoaderPair :: MemLoaderState v w -> (SectionIndexMap v w, Memory w)
memLoaderPair mls = (mls^.mlsIndexMap, mls^.mlsMemory)

type MemLoader v w = StateT (MemLoaderState v w) (Except String)

insertMemSegment' :: MemWidth w => String -> MemSegment w -> MemLoader v w ()
insertMemSegment' nm seg =
  StateT $ \mls -> do
  case insertMemSegment seg (mls^.mlsMemory) of
    Left e ->
      throwError $ nm ++ " " ++ showInsertError e
    Right mem' -> do
      pure ((), mls & mlsMemory .~ mem')

-- | Maps file offsets to the elf section
type ElfFileSectionMap v = IntervalMap v (ElfSection v)


------------------------------------------------------------------------
-- RelocMap


-- | Maps symbols to their relocated target
type RelocMap w = Map w SymbolRef

checkZeroAddend :: ( Eq (ElfIntType (RelocationWidth tp))
                   , Num (ElfIntType (RelocationWidth tp))
                   )
                => RelaEntry tp
                -> Either String ()
checkZeroAddend rel =
  when (r_addend rel /= 0) $ Left "Cannot relocate symbols with non-zero addend."

relaSymbol  :: V.Vector v -> RelaEntry tp -> Either String v
relaSymbol symtab rel =
  case symtab V.!? fromIntegral (r_sym rel) of
    Nothing -> Left $ "Could not find symbol at index " ++ show (r_sym rel) ++ "."
    Just sym -> Right sym

-- | Creates a map that forwards addresses to be relocated to their appropriate target.
relaTarget :: V.Vector SymbolRef
           -> RelaEntry X86_64_RelocationType
           -> Either String (Maybe SymbolRef)
relaTarget symtab rel =
  case r_type rel of
    R_X86_64_GLOB_DAT -> do
      checkZeroAddend rel
      Just <$> relaSymbol symtab rel
    R_X86_64_COPY -> Right Nothing
    R_X86_64_JUMP_SLOT -> do
      checkZeroAddend rel
      Just <$> relaSymbol symtab rel
    tp -> Left $ "Do not yet support relocation type: " ++ show tp

-- | Creates a map that forwards addresses to be relocated to their appropriate target.
relocEntry :: V.Vector SymbolRef
           -> RelaEntry X86_64_RelocationType
           -> Either String (Maybe (MemWord 64, SymbolRef))
relocEntry symtab rel = fmap (fmap f) $ relaTarget symtab rel
  where f :: a -> (MemWord 64, a)
        f tgt = (memWord64 (r_offset rel), tgt)


-- Given a list returns a map mapping keys to their associated values, or
-- a key that appears in multiple elements.
mapFromListUnique :: Ord k => [(k,v)] -> Either k (Map k v)
mapFromListUnique = foldlM f Map.empty
  where f m (k,v) =
          case Map.lookup k m of
            Nothing -> Right $! Map.insert k v m
            Just _ -> Left k

-- | Creates a map that forwards addresses to be relocated to their appropriate target.
mkRelocMap :: V.Vector SymbolRef
           -> [RelaEntry X86_64_RelocationType]
           -> Either String (RelocMap (MemWord 64))
mkRelocMap symtab l = do
  mentries <- traverse (relocEntry symtab) l
  let errMsg w = show w ++ " appears in multiple relocations."
  case mapFromListUnique $ catMaybes mentries of
    Left dup -> Left (errMsg dup)
    Right v -> Right v

mkSymbolVersion :: VersionId -> SymbolVersion
mkSymbolVersion ver = SymbolVersion { symbolVersionFile = verFile ver
                                    , symbolVersionName = verName ver
                                    }

mkSymbolRef :: VersionedSymbol tp -> SymbolRef
mkSymbolRef (sym, mverId) =
  SymbolRef { symbolName = steName sym
            , symbolVersion = mkSymbolVersion <$> mverId
            }

-- | Creates a relocation map for the givenphdr
relocMapOfDynamic :: ElfData
                  -> RelaWidth w
                  -> ElfMachine
                  -> VirtAddrMap (ElfWordType w)
                  -> L.ByteString -- ^ Contents of .dynamic section
                  -> MemLoader (ElfWordType w) w (RelocMap (MemWord w))
relocMapOfDynamic d w mach virtMap dynContents =
  case (w, mach) of
    (Rela64, EM_X86_64) -> do
      dynSection <- either (throwError . show) pure $
        dynamicEntries d (relaClass w) virtMap dynContents
      relocs <- either (throwError . show) pure $
        dynRelocations (dynSection :: DynamicSection X86_64_RelocationType)
      syms <- either (throwError . show) pure $
        dynSymTable dynSection
      either throwError pure $
        mkRelocMap (mkSymbolRef <$> syms) relocs
    _ -> throwError $ "Dynamic libraries are not supported on " ++ show mach ++ "."

------------------------------------------------------------------------
-- Elf segment loading

-- | Load an elf file into memory.
insertElfSegment :: (Integral v, MemWidth w)
                 => ElfFileSectionMap v
                 -> L.ByteString
                 -> RelocMap (MemWord w)
                    -- ^ Relocations to apply in loading section.
                 -> Phdr v
                 -> MemLoader v w ()
insertElfSegment shdrMap contents relocMap phdr = do
  idx <- use mlsIndex
  mlsIndex .= idx + 1
  let seg = memSegmentForElfSegment idx contents relocMap phdr
  let seg_idx = elfSegmentIndex (phdrSegment phdr)
  insertMemSegment' ("Segment " ++ show seg_idx) seg
  let phdr_offset = fromFileOffset (phdrFileStart phdr)
  let phdr_end = phdr_offset + phdrFileSize phdr
  let l = IMap.toList $ IMap.intersecting shdrMap (IntervalCO phdr_offset phdr_end)
  forM_ l $ \(i, sec) -> do
    case i of
      IntervalCO shdr_start _ -> do
        let elfIdx = ElfSectionIndex (elfSectionIndex sec)
        when (phdr_offset > shdr_start) $ do
          fail $ "Found section header that overlaps with program header."
        let sec_offset = fromIntegral $ shdr_start - phdr_offset
        let pair = (SegmentedAddr seg sec_offset, sec)
        mlsIndexMap %= Map.insert elfIdx pair
      _ -> fail "Unexpected shdr interval"

-- | Load an elf file into memory.  This uses the Elf segments for loading.
memoryForElfSegments :: forall w
                     .  (Integral (ElfWordType w), MemWidth w)
                     => RelaWidth w
                     -> Elf (ElfWordType w)
                     -> Either String (SectionIndexMap (ElfWordType w) w, Memory w)
memoryForElfSegments w e =
  runExcept $ fmap memLoaderPair $ flip execStateT (initState w) $ do
    let l   = elfLayout e
    let d   = elfLayoutData l
    let ph  = allPhdrs l
    let contents = elfLayoutBytes l
    virtMap <- maybe (throwError "Overlapping loaded segments") pure $
      virtAddrMap contents ph
    relocMap <-
      case filter (hasSegmentType PT_DYNAMIC . phdrSegment) ph of
        [] -> pure Map.empty
        [dynPhdr] ->
          let dynContents = sliceL (phdrFileRange dynPhdr) contents
           in relocMapOfDynamic d w (elfMachine e) virtMap dynContents
        _ -> throwError "Multiple dynamic sections"

    let intervals :: ElfFileSectionMap (ElfWordType w)
        intervals = IMap.fromList $
          [ (IntervalCO start end, sec)
          | shdr <- Map.elems (l^.shdrs)
          , let start = shdr^._3
          , let sec = shdr^._1
          , let end = start + elfSectionFileSize sec
          ]
    mapM_ (insertElfSegment intervals contents relocMap)
          (filter (hasSegmentType PT_LOAD . phdrSegment) ph)

------------------------------------------------------------------------
-- Elf section loading

-- | Load an elf file into memory.
insertElfSection :: (Integral v, Bits v, MemWidth w)
                 => ElfSection v
                 -> MemLoader v w ()
insertElfSection sec =
  when (elfSectionFlags sec `hasPermissions` shf_alloc) $ do
    idx <- use mlsIndex
    mlsIndex .= idx + 1
    let seg = memSegmentForElfSection idx sec
    insertMemSegment' ("Section " ++ BSC.unpack (elfSectionName sec)) seg
    let elfIdx = ElfSectionIndex (elfSectionIndex sec)
    let pair = (SegmentedAddr seg 0, sec)
    mlsIndexMap %= Map.insert elfIdx pair

-- | Load allocated Elf sections into memory.
-- Normally, Elf uses segments for loading, but the segment information
-- tends to be more precise.
memoryForElfSections :: (Integral (ElfWordType w), Bits (ElfWordType w), MemWidth w)
                     => RelaWidth w
                     -> Elf (ElfWordType w)
                     -> Either String (SectionIndexMap (ElfWordType w) w, Memory w)
memoryForElfSections w e =
  runExcept $ fmap memLoaderPair $ flip execStateT (initState w) $ do
    traverseOf_ elfSections insertElfSection e

------------------------------------------------------------------------
-- High level loading

-- | Pretty print parser errors to stderr.
ppErrors :: FilePath -> [ElfParseError w] -> IO ()
ppErrors path errl = do
  when (not (null errl)) $ do
    hPutStrLn stderr $ "Non-fatal errors during parsing " ++ path
  forM_ errl $ \e -> do
    hPutStrLn stderr $ "  " ++ show e

-- | This reads the elf file from the given path.
--
-- As a side effect it may print warnings for errors encountered during parsing
-- to stderr.
readElf :: FilePath -> IO (SomeElf Elf)
readElf path = do
  bs <- BS.readFile path
  case parseElf bs of
    ElfHeaderError _ msg -> do
      fail $ "Could not parse Elf header: " ++ msg
    Elf32Res errl e -> do
      ppErrors path errl
      return (Elf32 e)
    Elf64Res errl e -> do
      ppErrors path errl
      return (Elf64 e)

loadExecutable :: FilePath -> IO SomeMemory
loadExecutable path = do
  se <- readElf path
  case se of
    Elf64 e -> either fail (return . Memory64 . snd) $
      memoryForElfSegments Rela64 e
    Elf32 e -> either fail (return . Memory32 . snd) $
      memoryForElfSegments Rela32 e

loadElfBySection :: FilePath -> IO SomeMemory
loadElfBySection path = do
  se <- readElf path
  case se of
    Elf64 e -> either fail (return . Memory64 . snd) $ memoryForElfSections Rela64 e
    Elf32 e -> either fail (return . Memory32 . snd) $ memoryForElfSections Rela32 e
