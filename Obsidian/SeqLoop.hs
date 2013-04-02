{-# LANGUAGE ScopedTypeVariables #-} 
{-

   sequential loops with state
   2013 : Joel Svensson 

-}

module Obsidian.SeqLoop where


import Obsidian.Program
import Obsidian.Exp
import Obsidian.Array
import Obsidian.Memory
import Obsidian.Names

-- TODO: Add suitable allocs
-- TODO: Rename module to something better

---------------------------------------------------------------------------
-- seqFold (actually reduce) 
---------------------------------------------------------------------------

seqFold :: forall l a. (ASize l, MemoryOps a)
           => (a -> a -> a)
           -> a
           -> Pull l a
           -> Program Thread a
seqFold op init arr = do
  ns  <- names "v" (undefined :: a) 
  allocateScalar ns (undefined :: a)

  assignScalar ns init  
  -- Assign nom [] init  
  SeqFor n $ \ ix ->
    do
      assignScalar ns (readFrom ns `op`  (arr ! ix))
      return None

    
  return $ readFrom ns
  where 
    n = sizeConv$ len arr


---------------------------------------------------------------------------
-- Sequential scan
---------------------------------------------------------------------------

seqScan :: forall l a. (ASize l, MemoryOps a)
           => (a -> a -> a)
           -> Pull l a
           -> Push Thread l a
seqScan op (Pull n ixf)  =
  Push n $ \wf -> do
    ns <- names "v" (undefined :: a) 
    allocateScalar ns (undefined :: a)
    assignScalar ns (ixf 0)
    wf (readFrom ns) 0 
    SeqFor (sizeConv (n-1)) $ \ix -> do
      wf (readFrom ns) ix                  
      assignScalar ns  $ readFrom ns `op` (ixf (ix + 1))
      return None
                 
---------------------------------------------------------------------------
-- Sequential Map (here for uniformity) 
---------------------------------------------------------------------------

seqMap :: forall l a b. ASize l
          => (a -> b)
          -> Pull l a
          -> Push Thread l b
seqMap f arr =
  Push (len arr) $ \wf -> do
    SeqFor (sizeConv (len arr)) $ \ix ->
      wf (f (arr ! ix)) ix 


---------------------------------------------------------------------------
-- Sequential Map and scan (generalisation of map + accum) 
---------------------------------------------------------------------------

seqMapScan :: forall l a b acc. (ASize l, MemoryOps acc, MemoryOps b)
              => (acc -> a -> (acc,b))
              -> acc 
              -> Pull l a
              -> Push Thread l (acc,b)
seqMapScan op acc (Pull n ixf)  =
  Push n $ \wf -> do
    ns <- names "v" (undefined :: b) 
    allocateScalar ns (undefined :: b)
    nacc <- names "v" (undefined :: acc)
    allocateScalar nacc (undefined :: acc)
    
    assignScalar nacc acc

    SeqFor (sizeConv n) $ \ix -> do
      let (a,b) = op (readFrom nacc) (ixf ix)
      wf (a,b) ix                  
      assignScalar nacc a
      return None