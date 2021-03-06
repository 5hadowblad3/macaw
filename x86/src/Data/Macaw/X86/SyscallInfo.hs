{-|
Copyright  : (c) Galois, Inc 2016
Maintainer : jhendrix@galois.com

Data structures used for defining how system calls are interpreted.
-}
module Data.Macaw.X86.SyscallInfo
  ( SyscallPersonality(..)
  , SyscallTypeInfo
  , SyscallArgType(..)
  ) where

import qualified Data.Map as Map
import           Data.Parameterized.Some
import           Data.Word

import           Data.Macaw.X86.X86Reg

data SyscallArgType = VoidArgType | WordArgType
  deriving (Eq, Show, Read)

-- | Information about a specific syscall.
--
-- This contains the name, the result type, and the argument types.
type SyscallTypeInfo = (String, SyscallArgType, [SyscallArgType])

data SyscallPersonality =
  SyscallPersonality { spTypeInfo :: Map.Map Word64 SyscallTypeInfo
                     , spResultRegisters :: [Some X86Reg]
                     }
