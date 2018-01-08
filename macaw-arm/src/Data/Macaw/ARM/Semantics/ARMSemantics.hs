{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-spec-constr -fno-specialise -fmax-simplifier-iterations=1 -fno-call-arity #-}

module Data.Macaw.ARM.Semantics.ARMSemantics
    ( execInstruction
    )
    where

import           Data.Macaw.ARM.Arch ( armInstructionMatcher )
import           Data.Macaw.ARM.ARMReg ( locToRegTH )
import           Data.Macaw.ARM.Semantics.TH ( armAppEvaluator, armNonceAppEval )
import qualified Data.Macaw.CFG as MC
import           Data.Macaw.SemMC.Generator ( Generator )
import           Data.Macaw.SemMC.TH ( genExecInstruction )
import qualified Data.Macaw.Types as MT
import           Data.Proxy ( Proxy(..) )
import qualified Dismantle.ARM as D
import           SemMC.ARM ( ARM, Instruction )
import           SemMC.Architecture.ARM.Opcodes ( allSemantics, allOpcodeInfo )


execInstruction :: MC.Value ARM ids (MT.BVType 32) -> D.Instruction -> Maybe (Generator ARM ids s ())
execInstruction = $(genExecInstruction (Proxy @ARM)
                                           (locToRegTH (Proxy @ARM))
                                           armNonceAppEval
                                           armAppEvaluator
                                           'armInstructionMatcher
                                            allSemantics
                                            allOpcodeInfo)
