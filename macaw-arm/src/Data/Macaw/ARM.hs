{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- {-# LANGUAGE FlexibleContexts #-}
-- {-# LANGUAGE ScopedTypeVariables #-}
-- {-# LANGUAGE RankNTypes #-}
-- {-# LANGUAGE GADTs #-}
-- {-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Data.Macaw.ARM
    ( -- * Macaw configurations
      arm_linux_info,
      -- * Type-level tags
      ARM,
      -- * ELF support
      -- tocBaseForELF
      -- tocEntryAddrsForELF
    )
    where


import qualified Data.Macaw.ARM.Semantics.ARMSemantics as ARMSem
import qualified Data.Macaw.AbsDomain.AbsState as MA
import qualified Data.Macaw.Architecture.Info as MI
import           Data.Macaw.CFG ( ArchSegmentOff )
import qualified Data.Macaw.Memory as MM
import           Data.Macaw.Types ( BVType )
import qualified SemMC.ARM as ARM
import           Data.Proxy ( Proxy(..) )
import           Data.Macaw.ARM.ARMReg


-- | The type tag for ARM (32-bit)
type ARM = ARM.ARM


-- arm_linux_info :: (ArchSegmentOff ARM.ARM -> Maybe (MA.AbsValue 32 (BVType 32))) -> MI.ArchitectureInfo ARM.ARM
arm_linux_info :: MI.ArchitectureInfo ARM.ARM
arm_linux_info =
    MI.ArchitectureInfo { MI.withArchConstraints = undefined -- id -- \x -> x
                        , MI.archAddrWidth = MM.Addr32
                        , MI.archEndianness = MM.LittleEndian
                        , MI.jumpTableEntrySize = undefined -- jumpTableEntrySize proxy
                        , MI.disassembleFn = undefined -- disassembleFn proxy ARMSem.execInstruction
                        , MI.mkInitialAbsState = undefined -- mkInitialAbsState proxy tocMap
                        , MI.absEvalArchFn = undefined -- absEvalArchFn proxy
                        , MI.absEvalArchStmt = undefined -- absEvalArchStmt proxy
                        , MI.postCallAbsState = undefined -- postCallAbsState proxy
                        , MI.identifyCall = undefined -- identifyCall proxy
                        , MI.identifyReturn = undefined -- identifyReturn proxy
                        , MI.rewriteArchFn = undefined -- rewritePrimFn
                        , MI.rewriteArchStmt = undefined -- rewriteStmt
                        , MI.rewriteArchTermStmt = undefined -- rewriteTermStmt
                        , MI.archDemandContext = undefined -- archDemandContext proxy
                        , MI.postArchTermStmtAbsState = undefined -- postARMTermStmtAbsState (preserveRegAcrossSyscall proxy)
                        }
        where
          proxy = Proxy @ARM.ARM
