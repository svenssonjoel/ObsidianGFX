{- Joel Svensson 2012, 2013 
   Mary Sheeran  2012

   Notes:
   2013-01-24: GlobPull nolonger exists
               GlobPush is Push Grid
              
   2013-01-08: Renamed GlobArray to GlobPush 
   2013-01-02: Added toGlobArray and toGlobArrayN
   2012-12-10: Refactoring
               (adherence to new Array types and program types)  
-}

{-# LANGUAGE FlexibleInstances,
             TypeSynonymInstances,
             ScopedTypeVariables,
             TypeFamilies,
             GADTs #-}

module Obsidian.Library where 

import Obsidian.Array 
import Obsidian.Exp 
import Obsidian.Program
import Obsidian.Types

import Obsidian.Force

-- needed for threadsPerBlock analysis 
import qualified Obsidian.CodeGen.Program as P 

import Data.Bits 
import Data.Word

import Prelude hiding (splitAt,zipWith,replicate,reverse)


---------------------------------------------------------------------------
-- Fix the size of an array. Use to generate kernels for fixed sizes
---------------------------------------------------------------------------
fixSize :: Word32 -> DPull a -> SPull a
fixSize w arr = mkPull w $ \ix -> arr ! ix


---------------------------------------------------------------------------
-- Reverse an array by indexing in it backwards
---------------------------------------------------------------------------
  
reverse :: ASize l => Pull l a -> Pull l a 
reverse arr = mkPull n (\ix -> arr ! ((sizeConv m) - ix))  
   where m = n-1
         n = len arr
         
---------------------------------------------------------------------------
-- splitAt (name clashes with Prelude.splitAt)
---------------------------------------------------------------------------
splitAt :: (Integral i, ASize l) => i -> Pull l a -> (Pull l a, Pull l a) 
splitAt n arr = (mkPull m (\ix -> arr ! ix), 
                 mkPull  (len arr - m) (\ix -> arr ! (ix + pos)))
  where pos = fromIntegral n
        m   = fromIntegral n


halve arr = splitAt n2 arr
  where 
    n = len arr
    n2 = n `div` 2

splitUp :: ASize l => Word32 -> Pull l a -> Pull l (SPull a)
splitUp n arr {-(Pull m ixf)-} =
  mkPull (len arr `div` fromIntegral n) $ \i ->
    mkPull n $ \j -> arr ! (i * (sizeConv n) + j)                                               


coalesce :: (ASize l, Num l)
         => l -> Pull l a -> Pull l (Pull l a)
coalesce n arr =
  mkPull s $ \i ->
    mkPull n $ \j -> arr ! (i + (sizeConv s) * j)
  where s = (len arr) `div` n

---------------------------------------------------------------------------
-- everyNth 
---------------------------------------------------------------------------

everyNth :: ASize l => Word32 -> Word32 -> Pull l a -> Pull l a
everyNth n m arr = mkPull n' $ \ix -> arr ! (ix * (fromIntegral n) + fromIntegral m)
  where
    n' = len arr `div` (fromIntegral n) 
  

---------------------------------------------------------------------------
-- replicate 
---------------------------------------------------------------------------
replicate n a = mkPull n (\ix -> a)

singleton a = replicate 1 a

-- From Niklas
iterations n = mkPull n id 

---------------------------------------------------------------------------
-- last
---------------------------------------------------------------------------

last arr = arr ! fromIntegral ( len arr - 1)
first arr = arr ! 0 

---------------------------------------------------------------------------
-- Take and Drop (what about strange sizes ? fix) 
---------------------------------------------------------------------------
take :: ASize l => l -> Pull l a -> Pull l a
take n arr = setSize n arr

drop :: ASize l => l -> Pull l a -> Pull l a
drop n arr = setSize (len arr - n) $ ixMap (\ix -> ix + sizeConv n) arr

---------------------------------------------------------------------------
-- Shift arrays
---------------------------------------------------------------------------
shiftRight :: (ASize l, Choice a) => Word32 -> a -> Pull l a -> Pull l a
shiftRight dist elt arr = setSize (len arr)
                          $ replicate (fromIntegral dist) elt `conc` arr

-- TODO: incorrect! 
shiftLeft :: (ASize l, Choice a) => Word32 -> a -> Pull l a -> Pull l a
shiftLeft dist elt arr = mkPull (len arr)
                         $ \ix -> (arr `conc`  replicate (fromIntegral dist) elt)
                                  ! (ix + fromIntegral dist) 
                         
---------------------------------------------------------------------------
-- elements at even indices to fst output, odd to snd.
---------------------------------------------------------------------------
evenOdds :: ASize l => Pull l a -> (Pull l a, Pull l a)
evenOdds arr = (mkPull (n-n2) (\ix -> arr ! (2*ix)) ,
                mkPull n2     (\ix -> arr ! (2*ix + 1)))
  where
    n  = len arr
    n2 = div n 2
    
evens, odds :: ASize l => Pull l a -> Pull l a
evens = fst . evenOdds
odds  = snd . evenOdds

-- opposite of evenOdds 
--shuffle :: ASize l => PT t -> Pull l a -> Pull l a -> Push t l a
--shuffle Block a1 a2 =
--  Push (len a1 + len a2) $
--    \ wf -> ForAll (sizeConv (len a1)) $
--            \ tid -> do
--              wf (a1 ! tid) (tid * 2) 
--              wf (a2 ! tid) (tid * 2 + 1) 


---------------------------------------------------------------------------
-- Concatenate the arrays
---------------------------------------------------------------------------
conc :: (ASize l, Choice a) => Pull l a -> Pull l a -> Pull l a 
conc a1 a2 = mkPull (n1+n2)
               $ \ix -> ifThenElse (ix <* (sizeConv n1)) 
                       (a1 ! ix) 
                       (a2 ! (ix - (sizeConv n1)))
  where 
    n1 = len a1
    n2 = len a2 

    
---------------------------------------------------------------------------
-- zipp unzipp
---------------------------------------------------------------------------
unzipp :: ASize l =>  Pull l (a,b) -> (Pull l a, Pull l b)       
unzipp arr = (mkPull (len arr) (\ix -> fst (arr ! ix)) ,
              mkPull (len arr) (\ix -> snd (arr ! ix)) )
              
zipp :: ASize l => (Pull l a, Pull l b) -> Pull l (a, b)             
zipp (arr1,arr2) = mkPull (min (len arr1) (len arr2))
                     $ \ix -> (arr1 ! ix, arr2 ! ix) 

zip :: ASize l =>  Pull l a -> Pull l b -> Pull l (a, b)    
zip = curry zipp

unzipp3 :: ASize l => Pull l (a,b,c) 
           -> (Pull l a, Pull l b, Pull l c)       
unzipp3 arr = (fmap (\(x,_,_) -> x) arr,
               fmap (\(_,y,_) -> y) arr,
               fmap (\(_,_,z) -> z)  arr) 


zipp3 :: ASize l =>  (Pull l a, Pull l b, Pull l c) 
         -> Pull l (a,b,c)             
zipp3 (arr1,arr2,arr3) = 
  mkPull (minimum [len arr1, len arr2, len arr3])
  (\ix -> (arr1 ! ix, arr2 ! ix, arr3 ! ix))
    

zipWith :: ASize l => (a -> b -> c) -> Pull l a -> Pull l b -> Pull l c
--zipWith :: Ord l => (a -> b -> c) -> Pull l a -> Pull l b -> Pull l c
zipWith op a1 a2 =  
  mkPull (min (len a1) (len a2))
  (\ix -> (a1 ! ix) `op` (a2 ! ix))


zipWith3 :: ASize l => (a -> b -> c-> d) -> Pull l a -> Pull l b -> Pull l c -> Pull l d
zipWith3 f a1 a2 a3 =  
  mkPull (minimum [len a1,len a2,len a3]) $ 
    \ix -> f (a1 ! ix)  (a2 ! ix) (a3 ! ix)

  
---------------------------------------------------------------------------
-- pair 
---------------------------------------------------------------------------
pair :: ASize l => Pull l a -> Pull l (a,a)
pair arr {-(Pull n ixf)-} = 
  mkPull n' (\ix -> (arr ! (ix*2),arr ! (ix*2+1))) 
  where 
    n' = len arr `div` 2 



unpair :: ASize l => Choice a => Pull l (a,a) -> Pull l a
unpair arr = 
    let n = len arr
    in  mkPull (2*n) (\ix -> ifThenElse ((mod ix 2) ==* 0) 
                                  (fst (arr ! (ix `shiftR` 1)))
                                  (snd (arr ! (ix `shiftR` 1)))) 


---------------------------------------------------------------------------
-- twoK (untested for proper functionality) 
---------------------------------------------------------------------------

binSplit = twoK

-- See if this should be specifically for Static size pull arrays
twoK ::Int -> (Pull Word32 a -> Pull Word32 b) -> Pull Word32 a -> Pull Word32 b 
twoK 0 f = f  -- divide 0 times and apply f
twoK n f = \arr -> 
              let arr' = mkPull lt (\i -> (f (mkPull  m (\j -> (arr ! (g i j)))) ! (h i))) 
                  m    = (len arr `shiftR` n)   --pow of two           
                  g i j = i .&. (fromIntegral (complement (m-1))) .|. j  
                  h i   = i .&. (fromIntegral (nl2-1))   -- optimize 

                  nl2   = len (f (mkPull  m (\j -> arr ! variable "X")))
                  lt    = nl2 `shiftL` n 
              in arr'



---------------------------------------------------------------------------
-- ***                          PUSHY LIBRARY                       *** ---
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Concatenate on Push arrays 
---------------------------------------------------------------------------

concP :: ASize l
         => Push t l a -> Push t l a -> Push t l a 
concP p1 p2  =
  mkPush (n1 + n2) $ \wf ->
  do
    p1 <: wf
    p2 <: \a i -> wf a (sizeConv n1 + i) 
 where 
   n1 = len p1
   n2 = len p2 


-- More general versions of this can be imagined 
-- mergeL :: (EWord32 -> a -> a -> a) -> Pull Word32 a -> Pull Word32 a -> Push Block Word32 a
-- mergeL _ arr1 arr2 | len arr1 /= len arr2 = error "incorrect lengths" 
-- mergeL f arr1 arr2 =
--   mkPush (len arr1) $ \wf ->
--   do
--     forAll (sizeConv (len arr1)) $
--       \ tid -> wf (f tid (arr1 ! tid) (arr2 ! tid)) tid 

-- Implement unpair on pusharrays,
-- Impement for more tuples than pairs. 
--unpair :: ASize l => Choice a => Pull l (a,a) -> Pull l a
--unpair arr = 
--    let n = len arr
--    in  mkPull (2*n) (\ix -> ifThenElse ((mod ix 2) ==* 0) 
--                                  (fst (arr ! (ix `shiftR` 1)))
--                                  (snd (arr ! (ix `shiftR` 1)))) 



---------------------------------------------------------------------------
-- Singleton push arrays 
---------------------------------------------------------------------------

singletonP a =
  mkPush 1 $ \wf ->
  do
    a' <- a
    wf a' 0 


-- Danger! use only with Scalar a's 
singletonPush :: Program t a -> SPush t a
singletonPush prg =
  mkPush 1 $ \wf -> do
    a <- prg
    forAll 1 $ \ix -> 
      wf a 0
-- Danger! use only with Scalar a's
singletonPush' :: a -> SPush t a
singletonPush' = singletonPush . return 
