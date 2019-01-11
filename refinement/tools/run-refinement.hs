{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}

import           Control.Lens
import           Control.Monad
import qualified Control.Monad.Catch as X
import           Control.Monad.IO.Class
import qualified Data.ByteString as BS
import qualified Data.ElfEdit as E
import           Data.Foldable
import qualified Data.Macaw.Architecture.Info as AI
import           Data.Macaw.BinaryLoader as MBL
import           Data.Macaw.BinaryLoader.X86 ()
import qualified Data.Macaw.Discovery as MD
import qualified Data.Macaw.Memory.ElfLoader as ML
import           Data.Macaw.PPC
import qualified Data.Macaw.X86 as MX86
import qualified Data.Map as M
import           Data.Parameterized.Some
import qualified Options.Applicative as O
import qualified Options.Applicative.Extra as OE
import qualified SemMC.Architecture.PPC64 as PPC64
import           System.Exit

data Options = Options { inputFile :: FilePath
                       , unrefined :: Bool
                       }

optionsParser :: O.Parser Options
optionsParser = Options
                <$> O.strArgument ( O.metavar "FILE"
                                    <> O.help "The binary ELF file to perform discovery on"
                                  )
                <*> O.switch ( O.long "unrefined"
                             <> O.help "No refinement of discovery results"
                             )

main :: IO ()
main = O.execParser optParser >>= doRefinement
  where optParser = O.info ( optionsParser O.<**> O.helper )
                    ( O.fullDesc
                    <> O.progDesc "A tool to show refined code discovery for ELF binaries"
                    <> O.header "run-refinement - code discovery output"
                    )

doRefinement :: Options -> IO ()
doRefinement opts = do
  let filename = inputFile opts
  bs <- BS.readFile filename
  elf <- case E.parseElf bs of
      E.Elf64Res warnings elf -> mapM_ print warnings >> return elf
      _ -> die "not a 64-bit ELF file"
  case E.elfMachine elf of
      E.EM_PPC64 -> do
        bin <- MBL.loadBinary @PPC64.PPC ML.defaultLoadOptions elf
        let pli = ppc64_linux_info bin
        withBinaryDiscoveredInfo opts (showDiscoveryInfo opts) pli bin
      E.EM_X86_64 ->
        withBinaryDiscoveredInfo opts (showDiscoveryInfo opts) MX86.x86_64_linux_info =<<
          MBL.loadBinary @MX86.X86_64 ML.defaultLoadOptions elf
      -- E.EM_X86_64 -> case ML.resolveElfContents ML.defaultLoadOptions elf of
      --   Left e -> fail (show e)
      --   Right (_, _, Nothing, _) -> fail "Couldn't work out entry point."
      --   Right (warn, mem, Just entryPoint, _) -> do
      --     mapM_ print warn
      --     putStr "Entrypoint: "; putStrLn $ show entryPoint
      --     showDiscoveryInfo opts $ MD.cfgFromAddrs MX86.x86_64_linux_info mem M.empty [entryPoint] []
      _ -> error "only X86 and PPC64 supported for now"


withBinaryDiscoveredInfo :: ( X.MonadThrow m
                            , MBL.BinaryLoader arch binFmt
                            , MonadIO m) =>
                            Options
                         -> (MD.DiscoveryState arch -> m a)
                         -> AI.ArchitectureInfo arch
                         -> MBL.LoadedBinary arch binFmt
                         -> m a
withBinaryDiscoveredInfo opts f arch_info bin = do
  entries <- toList <$> entryPoints bin
  liftIO $ do putStr "Entrypoints: "
              putStrLn $ show $ fmap show entries
              -- putStrLn $ show (fmap (show . MM.segoffSegment) entries)
              -- putStrLn $ show (fmap (show . MM.segoffOffset) entries)
  let di = if unrefined opts
           then MD.cfgFromAddrs arch_info (memoryImage bin) M.empty entries []
           else error "refinement not supported yet"
  f di

showDiscoveryInfo _opts di =
  forM_ (M.toList (di ^. MD.funInfo)) $ \(funAddr, Some dfi) -> do
    putStrLn $ "===== BEGIN FUNCTION " ++ show funAddr ++ " ====="
    forM_ (M.toList (dfi ^. MD.parsedBlocks)) $ \(blockAddr, pb) -> do
      putStrLn $ "== begin block " ++ show blockAddr ++ " =="
      putStrLn . show $ MD.blockStatementList pb
      putStrLn ""
    putStrLn ""
    putStrLn ""
