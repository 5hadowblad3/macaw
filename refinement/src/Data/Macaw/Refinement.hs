{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

module Data.Macaw.Refinement
  ( cfgFromAddrsAndState
  , cfgFromAddrs
  , refineDiscovery
  )
where

import           Control.Lens
import qualified Data.Macaw.Architecture.Info as MA
import           Data.Macaw.CFG.AssignRhs
import qualified Data.Macaw.Discovery as MD
import           Data.Macaw.Discovery.State
import qualified Data.Macaw.Memory as MM
import           Data.Parameterized.Classes


-- | Expand an initial discovery state by exploring from a given set of function
-- entry points.  This entry point can be used as an alternative to the same named function in Data.Macaw.Discovery.
cfgFromAddrsAndState :: forall arch . ShowF (ArchReg arch) =>
                        MD.DiscoveryState arch
                     -> [ArchSegmentOff arch]
                     -- ^ Initial function entry points.
                     -> [(ArchSegmentOff arch, ArchSegmentOff arch)]
                     -- ^ Function entry points in memory to be explored
                     -- after exploring function entry points.
                     --
                     -- Each entry contains an address and the value stored in it.
                     -> DiscoveryState arch
cfgFromAddrsAndState initial_state init_addrs mem_words =
  MD.cfgFromAddrsAndState initial_state init_addrs mem_words
    & refineDiscovery

-- | Construct an empty discovery state and populate it by exploring
-- from a given set of function entry points.  This can be used as an
-- alternate entry point from the same named function in
-- Data.Macaw.Discovery.
cfgFromAddrs ::
     forall arch . ShowF (ArchReg arch) =>
     MA.ArchitectureInfo arch
     -- ^ Architecture-specific information needed for doing
     -- control-flow exploration.
     -> MM.Memory (ArchAddrWidth arch)
     -- ^ Memory to use when decoding instructions.
     -> AddrSymMap (ArchAddrWidth arch)
     -- ^ Map from addresses to the associated symbol name.
     -> [ArchSegmentOff arch]
     -- ^ Initial function entry points.
     -> [(ArchSegmentOff arch, ArchSegmentOff arch)]
     -- ^ Function entry points in memory to be explored
     -- after exploring function entry points.
     --
     -- Each entry contains an address and the value stored in it.
     -> DiscoveryState arch
cfgFromAddrs ainfo mem addrSymMap =
  cfgFromAddrsAndState (emptyDiscoveryState mem addrSymMap ainfo)


-- | Refine an existing discovery state by using a symbolic backend to
-- perform additional discovery for incomplete blocks.
refineDiscovery :: DiscoveryState arch -> DiscoveryState arch
refineDiscovery discState = discState
