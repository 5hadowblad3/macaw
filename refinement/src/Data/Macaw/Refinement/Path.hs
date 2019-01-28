module Data.Macaw.Refinement.Path
  ( FuncBlockPath
  , buildFuncPath
  , pathDepth
  , pathTo
  , takePath
  )
where

import           Control.Applicative
import           Data.Macaw.Discovery.State ( DiscoveryFunInfo )
import           Data.Macaw.Refinement.FuncBlockUtils ( BlockIdentifier
                                                      , blockInFunction
                                                      , blockTransferTo
                                                      , funBlockIDs
                                                      )
import           Data.Parameterized.Some


data FuncBlockPath arch =
  Path
  (BlockIdentifier arch) -- current block
  [FuncBlockPath arch] -- ancestors to this block (non-loop)
  [BlockIdentifier arch] -- previously seen ancestors (loop)


-- | Builds a list of all the back-paths through the specific
-- function.  The returned list is a list of all the exit points of
-- the function, with a FuncBlockPath tree indicating the blocks
-- forming the path to that exit point.
buildFuncPath :: Some (DiscoveryFunInfo arch) -> [FuncBlockPath arch]
buildFuncPath sfi@(Some fi) =
  let blks = funBlockIDs sfi
  in fst $ bldFPath fi ([], blks)


bldFPath :: DiscoveryFunInfo arch ids
         -> ([FuncBlockPath arch], [BlockIdentifier arch])
         -> ([FuncBlockPath arch], [BlockIdentifier arch])
bldFPath _fi x@(_, []) = x
bldFPath fi (fs, b:_) = ([Path b [] []], [])

-- | Given a function's call paths, return the subset of the call
-- paths that terminates with the specified block.  The specified
-- block might be reachable backward from several exit points, but the
-- inbound paths (i.e. above/forward to) the specified block must be
-- the same for all outbound paths (loops are elided).
pathTo :: BlockIdentifier arch -> [FuncBlockPath arch] -> Maybe (FuncBlockPath arch)
pathTo blkID (p@(Path i anc _):ps) =
  if blkID == i
  then Just p
  else let depth = pathTo blkID anc
           breadth = pathTo blkID ps
       in breadth <|> depth
pathTo _ [] = Nothing


takePath :: Int -> FuncBlockPath arch -> FuncBlockPath arch
takePath n (Path blkid anc loop) =
  if n > 0
  then Path blkid (takePath (n-1) <$> anc) loop
  else Path blkid [] loop


-- | Returns the maximum length (depth) of all paths through the
-- function (ignoring loops)
pathDepth :: FuncBlockPath arch -> Int
pathDepth (Path _ [] _) = 0
pathDepth (Path _ anc _) = 1 + maximum (pathDepth <$> anc)
