{-
   Copyright (c) Microsoft Corporation
   All rights reserved.

   Licensed under the Apache License, Version 2.0 (the ""License""); you
   may not use this file except in compliance with the License. You may
   obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR
   CONDITIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT
   LIMITATION ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR
   A PARTICULAR PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.

   See the Apache Version 2.0 License for specific language governing
   permissions and limitations under the License.
-}
{-# LANGUAGE GADTs, RankNTypes, DeriveGeneric, DeriveDataTypeable, ScopedTypeVariables, RecordWildCards #-}
{-# OPTIONS_GHC -Wall #-}
module AstComp where

import Prelude hiding (pi, mapM)
import Control.Arrow ((***))
import Control.Monad (forM, liftM)
import Control.Monad.State (State, execState, modify)
import Data.Data (Data)
import Data.Either (partitionEithers)
import Data.Functor.Identity ( Identity (..) )
import Data.Traversable (mapM)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Text.Parsec.Pos
import Text.Show.Pretty (PrettyVal)
import qualified Data.Set as S

import AstExpr
import PpExpr ()

{-------------------------------------------------------------------------------
  Comp types

  Although we do not distinguish between source and internal comp types, we
  _do_ distinguish between source and internal expression types, and since
  comp types include expression types, we parameterize by the expression type.
-------------------------------------------------------------------------------}

data GCTy0 ty where
  TComp :: ty -> ty -> ty -> GCTy0 ty
  TTrans :: ty -> ty -> GCTy0 ty
  deriving (Generic, Typeable, Data)

data GCTy ty where
  CTBase :: GCTy0 ty -> GCTy ty
  -- Invariant: non-empty list and CTy0 is not arrow
  CTArrow :: [CallArg ty (GCTy0 ty)] -> GCTy0 ty -> GCTy ty
  deriving (Generic, Typeable, Data)

{-------------------------------------------------------------------------------
  AST parameterized by type (see "AstExpr")
-------------------------------------------------------------------------------}

{- TODO -- replace all the let constructs with simpler binding forms
   NOTE: A similar data type exists in the parse as LetDecl.
data Bind a b
  = BindC Name (Comp a b)           -- Bind computation:       let comp x = ...
  | BindStruct String StructDef     -- Structure definition:   struct x = { ... }
  | BindE Name (Exp b)              -- Bind expression:        let x = ...
  | BindExtFun Name (Fun b)         -- Bind external function: let external f(...) : ty
  | BindFun Name (Fun b)            -- Bind ordinary function: let f(...) = ...
  | BindFunC Name CParams Locals    -- Bind comp. function:    let comp f(...) = ...
  | BindMonadic Name (Comp a b)     -- Bind from a monad:      x <- c
-}

data GComp0 tc t a b where
  -- | Variables
  Var :: GName tc -> GComp0 tc t a b

  -- | Monadic bind
  --
  -- This represents a chain of monadic binds, which is a good representation for
  -- flattening out stuff and nested binds etc. In other words
  --
  -- > x1 <- c1; x2 <- c2; ... xn <- cn
  --
  -- is represented as:
  --
  -- > BindMany c1 [(x1,c2), (x2,c3) .... (x_(n-1),cn)]
  BindMany :: GComp tc t a b -> [(GName t,GComp tc t a b)] -> GComp0 tc t a b

  -- | Sequential composition
  --
  -- TODO: The type checker translates this to `BindMany`. If we had a more
  -- complete distinction between source and internal syntax this could
  -- probably go (#71).
  Seq :: GComp tc t a b -> GComp tc t a b -> GComp0 tc t a b

  -- | Parallel composition
  --
  -- We can compose to transformers
  --
  -- > c1 :: ST T a b   c2 :: ST T b c
  -- > -------------------------------
  -- >     c1 >>> c2 :: ST T a c
  --
  -- or a transformer and a computer
  --
  -- > c1 :: ST (C u) a b   c2 :: ST T b c
  -- > -----------------------------------
  -- >      c1 >>> c2 :: ST (C u) a c
  --
  -- > c1 :: ST T a b   c2 :: ST (C u) b c
  -- > -----------------------------------
  -- >      c1 >>> c2 :: ST (C u) a c
  Par :: ParInfo -> GComp tc t a b -> GComp tc t a b -> GComp0 tc t a b

  -- | Bind a computation
  Let :: GName tc  -> GComp tc t a b -> GComp tc t a b -> GComp0 tc t a b

  -- | Bind an expression
  LetE :: GName t -> ForceInline -> GExp t b -> GComp tc t a b -> GComp0 tc t a b

  -- | Bind a mutable variable
  LetERef :: GName t -> Maybe (GExp t b) -> GComp tc t a b -> GComp0 tc t a b

  -- | Bind an expression function
  LetHeader :: GFun t b -> GComp tc t a b -> GComp0 tc t a b

  -- | Bind a computation function
  LetFunC :: GName tc
          -> [GName (CallArg t tc)]           -- params (could include computation types)
          -> [(GName t,Maybe (GExp t b))]     -- locals
          -> GComp tc t a b                   -- body
          -> GComp tc t a b                   -- rhs
          -> GComp0 tc t a b

  -- | Bind a struct definition
  LetStruct :: GStructDef t -> GComp tc t a b -> GComp0 tc t a b

  -- | Function call
  Call :: GName tc -> [CallArg (GExp t b) (GComp tc t a b)] -> GComp0 tc t a b

  -- | Emit a value to the output stream
  --
  -- >         e :: b
  -- > -----------------------
  -- > emit e :: ST (C ()) a b
  --
  -- Since the argument to `emit` does not determine `a`, we add it an an extra
  -- parameter to `Emit`.
  Emit :: t -> GExp t b -> GComp0 tc t a b

  -- | Emit an array of values to the output stream
  --
  -- >      e :: arr[n] b
  -- > ------------------------
  -- > emits e :: ST (C ()) a b
  --
  -- Since the argument to `emits` does not determine `a`, we add it an an extra
  -- parameter to `Emit`.
  Emits :: t -> GExp t b -> GComp0 tc t a b

  -- | Return a value
  --
  -- >         e :: u
  -- > ------------------------
  -- > return e :: ST (C u) a b
  --
  -- Since the argument to `return` does not determine `a` and `b` we add these
  -- as extra arguments.
  Return :: t -> t -> ForceInline -> GExp t b -> GComp0 tc t a b

  -- | Interleave
  --
  -- > c1 :: T a b    c2 :: T a b
  -- > --------------------------
  -- > Interleave c1 c2 :: T a b
  --
  -- TODO: We don't have source syntax for this?
  -- TODO: Not currently actually implemented in codegen?
  Interleave :: GComp tc t a b -> GComp tc t a b -> GComp0 tc t a b

  -- | Conditional
  Branch :: GExp t b -> GComp tc t a b -> GComp tc t a b -> GComp0 tc t a b

  -- | Take a value from the input stream
  --
  -- > --------------------
  -- > take :: ST (C a) a b
  --
  -- Since `take` has no arguments we record both `a` and `b` as parameters.
  Take1 :: t -> t -> GComp0 tc t a b

  -- | Take multiple values from the input stream
  --
  -- > --------------------------------
  -- > takes n :: ST (C (arr[n] a)) a b
  --
  -- Since `takes` has no arguments we record both `a` and `b` as parameters.
  Take :: t -> t -> Int -> GComp0 tc t a b

  -- | Iteration
  --
  -- > e :: Bool   c :: ST (C u) a b
  -- > -----------------------------
  -- >   until e c :: ST (C u) a b
  Until :: GExp t b -> GComp tc t a b -> GComp0 tc t a b

  -- | Iteration
  --
  -- > e :: Bool   c :: ST (C u) a b
  -- > -----------------------------
  -- >   while e c :: ST (C u) a b
  While :: GExp t b -> GComp tc t a b -> GComp0 tc t a b

  -- | Iteration
  --
  -- > e :: int<bw>   elen :: int<bw>   nm :: int<bw> |- c :: ST (C u) a b
  -- > -------------------------------------------------------------------
  -- >          times <unroll-info> e elen nm c :: ST (C u) a b
  --
  -- TODO: Replace with
  --
  -- > For :: GName ty -> GExp t b -> GExp t b -> GComp tc t a b -> GComp tc t 0 a a
  Times :: UnrollInfo -> GExp t b -> GExp t b -> GName t -> GComp tc t a b -> GComp0 tc t a b

  -- | Repeat a computer (to get a transformer)
  --
  -- >  c :: ST (C ()) a b
  -- > --------------------
  -- > repeat c :: ST T a b
  --
  -- Accepts an optional vectorization width annotation
  Repeat :: Maybe VectAnn -> GComp tc t a b -> GComp0 tc t a b

  -- | A computer annotated with vectorization width information.
  --
  -- NB: It must be a computer (not transformer).  Also notice we allow only
  -- rigid vectorization annotations here, the programmer must know what they
  -- are doing.
  VectComp :: (Int,Int) -> GComp tc t a b -> GComp0 tc t a b

  -- | Construct a transformer from a pure function
  --
  -- >    f :: a -> b
  -- > -----------------
  -- > map f :: ST T a b
  --
  -- Accepts an optional vectorization width annotation.
  Map :: Maybe VectAnn -> GName t -> GComp0 tc t a b

  -- | Filter an input stream
  --
  -- >     f :: a -> Bool
  -- > --------------------
  -- > filter f :: ST T a a
  Filter :: GName t -> GComp0 tc t a b

  -- | Read source
  --
  -- > ------------------------------
  -- > ReadSrc a :: ST T (ExtBuf a) a
  ReadSrc :: t -> GComp0 tc t a b

  -- | Write sink
  --
  -- > -------------------------------
  -- > WriteSnk a :: ST T a (ExtBuf a)
  WriteSnk :: t -> GComp0 tc t a b

  -- | Read from thread separator queue
  --
  -- > ---------------------------------
  -- > ReadInternal :: ST T (IntBuf a) a
  --
  -- Since this is polymorphic in `a` we add `a` as a parameter.
  --
  -- See Note [Standalone Reads] for `ReadType` (TODO: Where is this note?)
  ReadInternal :: t -> BufId -> ReadType -> GComp0 tc t a b

  -- | Write to thread separator queue
  --
  -- > ----------------------------------
  -- > WriteInternal :: ST T a (IntBuf a)
  --
  -- Since this is polymorphic in `a` we add `a` as a parameter.
  WriteInternal :: t -> BufId -> GComp0 tc t a b

  -- | Standalone computations (forked onto another core)
  --
  -- >      c :: ST T a b
  -- > ------------------------
  -- > standalone c :: ST T a b
  Standalone :: GComp tc t a b -> GComp0 tc t a b

  -- | Downgrade or upgrade the rate of components.
  --
  -- > n1, n2 > 1    (n2 `divides` n1 || n1 `divides` n2)
  -- > --------------------------------------------------
  -- >  Mitigate a n1 n2 :: ST T (arr[n1] a) (arr[n2] a)
  --
  -- >             n2 > 1
  -- > -------------------------------------
  -- > Mitigate a 1 n2 :: ST T a (arr[n2] a)
  --
  -- >             n1 > 1
  -- > -------------------------------------
  -- > Mitigate a n1 1 :: ST T (arr[n1] a) a
  --
  -- > --------------------------
  -- > Mitigate a 1 1 :: ST T a a
  Mitigate :: t -> Int -> Int -> GComp0 tc t a b
  deriving (Generic, Typeable, Data)

data VectAnn = Rigid Bool (Int,Int) -- True == allow mitigations up, False == disallow mitigations up
             | UpTo  Bool (Int,Int)
  deriving (Generic, Typeable, Data)


-- Call argument information
data CallArg a b
  = CAExp  { unCAExp  :: a }
  | CAComp { unCAComp :: b }
  deriving (Generic, Typeable, Data)

-- A view of some Pars as a list
data GParListView tc t a b
  = ParListView { plv_loc  :: CompLoc
                , plv_nfo  :: a
                , plv_head :: GComp tc t a b
                , plv_rest :: [(ParInfo,GComp tc t a b)]
                }

data PlInfo where
  AlwaysPipeline ::    Int -- use this thread id for c1
                    -> Int -- use this thread id for c2
                    -> PlInfo
  NeverPipeline  :: PlInfo
  MaybePipeline  :: PlInfo
  deriving (Generic, Typeable, Data)

data ParInfo
  = ParInfo { plInfo     :: PlInfo
            , inBurstSz  :: Maybe Int
            , outBurstSz :: Maybe Int }
  deriving (Generic, Typeable, Data)

-- See Note [Standalone Reads]
data ReadType
  = SpinOnEmpty
  | JumpToConsumeOnEmpty
  deriving (Generic, Typeable, Data)

type CompLoc = Maybe SourcePos

data GComp tc t a b
  = MkComp { unComp   :: GComp0 tc t a b
           , compLoc  :: CompLoc
           , compInfo :: a }
  deriving (Generic, Typeable, Data)

data GProg tc t a b
  = MkProg { globals  :: [(GName t,Maybe (GExp t b))]
           , progComp :: GComp tc t a b
           }
  deriving (Generic, Typeable, Data)

{-------------------------------------------------------------------------------
  Specialization of the AST to Ty (internal types)

  These types are used everywhere in the compiler except in the front-end.
-------------------------------------------------------------------------------}

type CTy0        = GCTy0  Ty
type CTy         = GCTy   Ty

type Comp0       = GComp0 CTy Ty () ()
type Comp        = GComp  CTy Ty () ()
type Prog        = GProg  CTy Ty () ()

type CId         = GName  CTy

type ParListView = GParListView CTy Ty () ()

{-------------------------------------------------------------------------------
  Specializations of the AST to SrcTy (source level types)

  These types are only used in the parser and the renamer, and as input
  to the type checker (which translates from SrcTy to Ty).
-------------------------------------------------------------------------------}

type SrcComp = GComp (Maybe (GCTy SrcTy)) (Maybe SrcTy) () ()
type SrcProg = GProg (Maybe (GCTy SrcTy)) (Maybe SrcTy) () ()

{-------------------------------------------------------------------------------
  Smart constructors
-------------------------------------------------------------------------------}

mkBind :: GComp tc t a b -> (GName t, GComp tc t a b) -> GComp0 tc t a b
mkBind c1 (n,c2) = mkBindMany c1 [(n,c2)]

mkBindMany :: GComp tc t a b -> [(GName t,GComp tc t a b)] -> GComp0 tc t a b
-- First push all the bindmany's on the list
mkBindMany = go
   where
     go (MkComp (BindMany c0 c0s) _ _) c1s = mkBindMany c0 (c0s++c1s)
     -- Now we know that 'c' is not a BindMany, empty continuation: just return
     go c [] = unComp c
     -- We know that 'c' is not a BindMany, but we do have a continuation, so
     -- recurse into the continuation to flatten the continuation this time.
     go c ((n,c1):cs)
       = case mkBindMany c1 cs of
           BindMany c1' c1s' -> BindMany c ((n,c1'):c1s')
           c1' -> BindMany c [(n, MkComp c1' (compLoc c1) (compInfo c1))]

{-------------------------------------------------------------------------------
  Various map functions

  Since these are used on both source terms and internal terms they have the
  general types where possible.
-------------------------------------------------------------------------------}

-- | General form of mapping over computations
--
-- NOTE: Not binding aware.
mapCompM :: forall tc tc' t t' a a' b b' m. Monad m
         => (tc -> m tc')                  -- ^ On comp types
         -> (t -> m t')                    -- ^ On expression types
         -> (a -> m a')                    -- ^ On comp annotations
         -> (b -> m b')                    -- ^ On expression annotations
         -> (GExp t b -> m (GExp t' b'))   -- ^ On expressions
         -> (GComp tc' t' a' b' -> m (GComp tc' t' a' b')) -- ^ Combine results
         -> GComp tc t a b
         -> m (GComp tc' t' a' b')
mapCompM onCTyp onETyp onCAnn onEAnn onExp f = goComp
  where
    goComp :: GComp tc t a b  -> m (GComp tc' t' a' b')
    goComp MkComp{..} = do
      unComp'   <- goComp0 unComp
      compInfo' <- onCAnn compInfo
      f MkComp{unComp = unComp', compInfo = compInfo', ..}

    goComp0 :: GComp0 tc t a b  -> m (GComp0 tc' t' a' b')
    goComp0 (Var x) = do
       x' <- mapNameM onCTyp x
       return $ Var x'
    goComp0 (BindMany c1 xs_cs) = do
       c1'    <- goComp c1
       xs_cs' <- forM  xs_cs $ \(x,c') -> do
                   x'  <- mapNameM onETyp x
                   c'' <- goComp c'
                   return (x', c'')
       -- TODO: we normalize at every node in the AST as we go up
       -- which is not terribly nice. Perhaps we should get rid of
       -- BindMany, in favor of plain old Bind, and have a
       -- bindManyView later on that gives us the functionality
       -- we need.
       return $ mkBindMany c1' xs_cs'
    goComp0 (Seq c1 c2) = do
      c1' <- goComp c1
      c2' <- goComp c2
      return $ Seq c1' c2'
    goComp0 (Par pi c1 c2) = do
      c1' <- goComp c1
      c2' <- goComp c2
      return $ Par pi c1' c2'
    goComp0 (Let x c1 c2) = do
      x'  <- mapNameM onCTyp x
      c1' <- goComp c1
      c2' <- goComp c2
      return $ Let x' c1' c2'
    goComp0 (LetStruct sdef c1) = do
      sdef' <- goStructDef sdef
      c1'   <- goComp c1
      return $ LetStruct sdef' c1'
    goComp0 (LetE x fi e c1) = do
      x'  <- mapNameM onETyp x
      e'  <- onExp e
      c1' <- goComp c1
      return $ LetE x' fi e' c1'
    goComp0 (LetERef x me c1) = do
      x' <- mapNameM onETyp x
      me' <- mapM onExp me
      c1' <- goComp c1
      return $ LetERef x' me' c1'
    goComp0 (LetHeader fun c1) = do
      fun' <- mapFunM onETyp onEAnn onExp fun
      c1'  <- goComp c1
      return $ LetHeader fun' c1'
    goComp0 (LetFunC nm params locals c1 c2) = do
      nm'     <- mapNameM onCTyp nm
      params' <- mapM (mapNameM goCallArgT) params
      locals' <- mapLocalsM onETyp onExp locals
      c1'     <- goComp c1
      c2'     <- goComp c2
      return $ LetFunC nm' params' locals' c1' c2'
    goComp0 (Call nm args) = do
      nm'   <- mapNameM onCTyp nm
      args' <- mapM goCallArg args
      return $ Call nm' args'
    goComp0 (Emit a e) = do
      a' <- onETyp a
      e' <- onExp e
      return $ Emit a' e'
    goComp0 (Return a b fi e) = do
      a' <- onETyp a
      b' <- onETyp b
      e' <- onExp e
      return $ Return a' b' fi e'
    goComp0 (Emits a e) = do
      a' <- onETyp a
      e' <- onExp e
      return $ Emits a' e'
    goComp0 (Interleave c1 c2) = do
      c1' <- goComp c1
      c2' <- goComp c2
      return $ Interleave c1' c2'
    goComp0 (Branch e c1 c2) = do
      e'  <- onExp e
      c1' <- goComp c1
      c2' <- goComp c2
      return $ Branch e' c1' c2'
    goComp0 (Take1 a b) = do
      a' <- onETyp a
      b' <- onETyp b
      return $ Take1 a' b'
    goComp0 (Take a b n) = do
      a' <- onETyp a
      b' <- onETyp b
      return $ Take a' b' n
    goComp0 (Until e c1) = do
      e'  <- onExp e
      c1' <- goComp c1
      return $ Until e' c1'
    goComp0 (While e c1) = do
      e'  <- onExp e
      c1' <- goComp c1
      return $ While e' c1'
    goComp0 (Times ui e elen nm c1) = do
      e'    <- onExp e
      elen' <- onExp elen
      nm'   <- mapNameM onETyp nm
      c1'   <- goComp c1
      return $ Times ui e' elen' nm' c1'
    goComp0 (Repeat wdth c1) = do
      c1' <- goComp c1
      return $ Repeat wdth c1'
    goComp0 (VectComp wdth c1) = do
      c1' <- goComp c1
      return $ VectComp wdth c1'
    goComp0 (Map wdth nm) = do
      nm' <- mapNameM onETyp nm
      return $ Map wdth nm'
    goComp0 (Filter nm) = do
      nm' <- mapNameM onETyp nm
      return $ Filter nm'
    goComp0 (ReadSrc a) = do
      a' <- onETyp a
      return $ ReadSrc a'
    goComp0 (WriteSnk a) = do
      a' <- onETyp a
      return $ WriteSnk a'
    goComp0 (ReadInternal a bid rt) = do
      a' <- onETyp a
      return $ ReadInternal a' bid rt
    goComp0 (WriteInternal a bid) = do
      a' <- onETyp a
      return $ WriteInternal a' bid
    goComp0 (Standalone c1) = do
      c1' <- goComp c1
      return $ Standalone c1'
    goComp0 (Mitigate t n1 n2) = do
      t' <- onETyp t
      return $ Mitigate t' n1 n2

    goCallArg :: CallArg (GExp t b) (GComp tc t a b) -> m (CallArg (GExp t' b') (GComp tc' t' a' b'))
    goCallArg (CAExp  e) = CAExp  `liftM` onExp e
    goCallArg (CAComp c) = CAComp `liftM` goComp c

    goCallArgT :: CallArg t tc -> m (CallArg t' tc')
    goCallArgT (CAExp  e) = CAExp  `liftM` onETyp e
    goCallArgT (CAComp c) = CAComp `liftM` onCTyp c

    goStructDef :: GStructDef t -> m (GStructDef t')
    goStructDef StructDef{..} = do
      struct_flds' <- forM struct_flds $ \(fld, t) -> do
                        t' <- onETyp t
                        return (fld, t')
      return StructDef{struct_flds = struct_flds', ..}

{-------------------------------------------------------------------------------
  Pure mapping functions
-------------------------------------------------------------------------------}

mapComp :: (tc -> tc')                  -- ^ On comp types
        -> (t -> t')                    -- ^ On expression types
        -> (a -> a')                    -- ^ On comp annotations
        -> (b -> b')                    -- ^ On expression annotations
        -> (GExp t b -> GExp t' b')     -- ^ On expressions
        -> (GComp tc' t' a' b' -> GComp tc' t' a' b') -- ^ Combine results
        -> GComp tc t a b
        -> GComp tc' t' a' b'
mapComp onCTyp onETyp onCAnn onEAnn onExp f =
    runIdentity . mapCompM (Identity . onCTyp)
                           (Identity . onETyp)
                           (Identity . onCAnn)
                           (Identity . onEAnn)
                           (Identity . onExp)
                           (Identity . f)

{-------------------------------------------------------------------------------
  Erase annotations
-------------------------------------------------------------------------------}

eraseComp :: GComp tc t a b -> GComp tc t () ()
eraseComp = mapComp id id (const ()) (const ()) eraseExp id

eraseCallArg :: CallArg (GExp t b) (GComp tc t a b) -> CallArg (GExp t ()) (GComp tc t () ())
eraseCallArg (CAExp  e) = CAExp  $ eraseExp e
eraseCallArg (CAComp c) = CAComp $ eraseComp c

{-------------------------------------------------------------------------------
  Free variables
-------------------------------------------------------------------------------}

type CompFVs tc t = (S.Set (GName tc), S.Set (GName t))

-- | Compute the free variables in a computation
--
-- NOTE: We collect in a bottom-up fashion, and assume that we are working with
-- a uniqued (renamed) and correctly scoped term; in other words, we assume
-- that variable names don't occur in subexpressions where they are not in
-- scope.
compFVs :: forall tc t a b. GComp tc t a b -> CompFVs tc t
compFVs = \c ->
    execState (mapCompM return return return return goExp goComp c)
              (S.empty, S.empty)
  where
    goComp :: GComp tc t a b -> State (CompFVs tc t) (GComp tc t a b)
    goComp c = goComp0 (unComp c) >> return c

    goComp0 :: GComp0 tc t a b -> State (CompFVs tc t) ()
    goComp0 (Var nm)               = recordC nm
    goComp0 (BindMany _ xcs)       = mapM_ unrecordE (map fst xcs)
    goComp0 (Let nm _ _)           = unrecordC nm
    goComp0 (LetE nm _ _ _)        = unrecordE nm
    goComp0 (LetERef nm _ _)       = unrecordE nm
    goComp0 (LetHeader fun _)      = unrecordE (funName fun)
    goComp0 (LetFunC nm ps ls _ _) = do unrecordC nm
                                        mapM_ unrecordCA ps
                                        mapM_ unrecordE (map fst ls)
    goComp0 (Call nm _)            = recordC nm
    goComp0 (Times _ _ _ nm _)     = unrecordE nm
    goComp0 (Map _v nm)            = recordE nm
    goComp0 (Filter nm)            = recordE nm

    goComp0 (Seq {})               = return ()
    goComp0 (Par {})               = return ()
    goComp0 (Emit {})              = return ()
    goComp0 (LetStruct {})         = return ()
    goComp0 (Emits {})             = return ()
    goComp0 (Return {})            = return ()
    goComp0 (Interleave {})        = return ()
    goComp0 (Branch {})            = return ()
    goComp0 (Take1 {})             = return ()
    goComp0 (Take {})              = return ()
    goComp0 (Until {})             = return ()
    goComp0 (While {})             = return ()
    goComp0 (Repeat {})            = return ()
    goComp0 (VectComp {})          = return ()
    goComp0 (ReadSrc {})           = return ()
    goComp0 (WriteSnk {})          = return ()
    goComp0 (ReadInternal {})      = return ()
    goComp0 (WriteInternal {})     = return ()
    goComp0 (Standalone {})        = return ()
    goComp0 (Mitigate {})          = return ()

    goExp :: GExp t b -> State (CompFVs tc t) (GExp t b)
    goExp e = modify (\(sc, s) -> (sc, S.union (exprFVs e) s)) >> return e

    recordE, unrecordE :: GName t -> State (CompFVs tc t) ()
    recordE   nm = modify $ \(sc, s) -> (sc, S.insert nm s)
    unrecordE nm = modify $ \(sc, s) -> (sc, S.delete nm s)

    recordC, unrecordC :: GName tc -> State (CompFVs tc t) ()
    recordC   nm = modify $ \(sc, s) -> (S.insert nm sc, s)
    unrecordC nm = modify $ \(sc, s) -> (S.delete nm sc, s)

    unrecordCA :: GName (CallArg t tc) -> State (CompFVs tc t) ()
    unrecordCA MkName{..} =
      case nameTyp of
        CAExp  t -> unrecordE MkName{nameTyp = t, ..}
        CAComp t -> unrecordC MkName{nameTyp = t, ..}

callArgFVs :: CallArg (GExp t b) (GComp tc t a b) -> CompFVs tc t
callArgFVs (CAExp e)  = (S.empty, exprFVs e)
callArgFVs (CAComp c) = compFVs c

compFVs_all :: [GComp tc t a b] -> CompFVs tc t
compFVs_all = (S.unions *** S.unions) . unzip . map compFVs

compCFVs :: GComp tc t a b -> S.Set (GName tc)
compCFVs = fst . compFVs

compEFVs :: GComp tc t a b -> S.Set (GName t)
compEFVs = snd . compFVs

{-------------------------------------------------------------------------------
  Substitution
-------------------------------------------------------------------------------}

substComp :: Monad m => (GName tc, GComp tc t a b) -> GComp tc t a b -> m (GComp tc t a b)
substComp (nm,c') = mapCompM return return return return return go
  where
    go c | Var nm' <- unComp c = if nm == nm' then return c' else return c
         | otherwise           = return c

substExpComp :: Monad m => (GName t, GExp t b) -> GComp tc t a b -> m (GComp tc t a b)
substExpComp (nm,e') = mapCompM return return return return (substExp (nm,e')) return

substAllComp :: Monad m => [(GName t, GExp t b)] -> GComp tc t a b -> m (GComp tc t a b)
substAllComp []     c = return c
substAllComp (s:ss) c = substExpComp s =<< substAllComp ss c

{-------------------------------------------------------------------------------
  Dealing with CallArgs
-------------------------------------------------------------------------------}

callArg :: (a -> c) -> (b -> c) -> CallArg a b -> c
callArg f _ (CAExp  a) = f a
callArg _ g (CAComp b) = g b

partitionCallArgs :: [CallArg a b] -> ([a], [b])
partitionCallArgs = partitionEithers . map (callArg Left Right)

partitionParams :: [GName (CallArg a b)] -> ([GName a], [GName b])
partitionParams = partitionEithers . map classify
  where
    classify :: GName (CallArg a b) -> Either (GName a) (GName b)
    classify nm = case nameTyp nm of
                     CAExp  t -> Left  nm{nameTyp = t}
                     CAComp t -> Right nm{nameTyp = t}

callArgExp :: CallArg a b -> Maybe a
callArgExp = callArg Just (const Nothing)

callArgComp :: CallArg a b -> Maybe b
callArgComp = callArg (const Nothing) Just

{-------------------------------------------------------------------------------
  Utility
-------------------------------------------------------------------------------}

isMaybeOrNever :: PlInfo -> Bool
isMaybeOrNever nfo =
  case nfo of
    AlwaysPipeline _ _ -> False
    NeverPipeline      -> True
    MaybePipeline      -> True


mkParInfo :: PlInfo -> ParInfo
mkParInfo nfo = ParInfo nfo Nothing Nothing

pnever :: ParInfo
pnever = mkParInfo NeverPipeline



parsToParList :: GComp tc t a b -> GParListView tc t a b
parsToParList c
  = ParListView { plv_loc  = compLoc c
                , plv_nfo  = compInfo c
                , plv_head = cfst
                , plv_rest = crest
                }
  where (cfst,crest) = go c
        go :: GComp tc t a b -> (GComp tc t a b, [(ParInfo, GComp tc t a b)])
        go (MkComp (Par p c1 c2) _loc _nfo)
          = let (c1fst,c1rest) = go c1
                (c2fst,c2rest) = go c2
            in (c1fst, c1rest ++ (p,c2fst) : c2rest)
        go cother = (cother, [])

readJumpToConsumeOnEmpty :: ReadType -> Bool
readJumpToConsumeOnEmpty JumpToConsumeOnEmpty = True
readJumpToConsumeOnEmpty _ = False


compShortName :: GComp tc t a b -> String
compShortName = go . unComp
  where
    go (Var n             ) = "Var(" ++ name n ++ ")"
    go (BindMany        {}) = "BindMany"
    go (Seq             {}) = "Seq"
    go (Par             {}) = "Par"
    go (Let             {}) = "Let"
    go (LetE            {}) = "LetE"
    go (LetERef         {}) = "LetERef"
    go (LetHeader fun _   ) = "LetHeader(" ++ name (funName fun) ++ ")"
    go (LetFunC nm _ _ _ _) = "LetFunC(" ++ name nm ++ ")"
    go (LetStruct       {}) = "Struct"
    go (Call n _          ) = "Call(" ++ name n ++ ")"
    go (Emit            {}) = "Emit"
    go (Emits           {}) = "Emits"
    go (Return          {}) = "Return"
    go (Interleave      {}) = "Interleave"
    go (Branch          {}) = "Branch"
    go (Take1           {}) = "Take1"
    go (Take            {}) = "Take"
    go (Until           {}) = "Until"
    go (While           {}) = "While"
    go (Times           {}) = "Times"
    go (Repeat          {}) = "Repeat"
    go (VectComp        {}) = "VectComp"
    go (Map             {}) = "Map"
    go (Filter          {}) = "Filter"
    go (ReadSrc         {}) = "ReadSrc"
    go (WriteSnk        {}) = "WriteSnk"
    go (ReadInternal    {}) = "ReadInternal"
    go (WriteInternal   {}) = "WriteInternal"
    go (Standalone      {}) = "Standalone"
    go (Mitigate        {}) = "Mitigate"

-- Just A binding context (for multiple threads)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- We may have to pipeline under a shared context and CompCtxt simply
-- records this shared context. We are not really using this context
-- in AstComp but it seems the right place to define this datatype.
data GCompCtxt tc t a b
  = Hole
  | CLet       CompLoc (GName tc) (GComp tc t a b) (GCompCtxt tc t a b)
  | CLetE      CompLoc (GName t) ForceInline (GExp t b) (GCompCtxt tc t a b)
  | CLetERef   CompLoc (GName t) (Maybe (GExp t b)) (GCompCtxt tc t a b)
  | CLetHeader CompLoc (GFun t b) (GCompCtxt tc t a b)
  | CLetFunC   CompLoc (GName tc) [GName (CallArg t tc)]       -- params
                                  [(GName t,Maybe (GExp t b))] -- locals
                                  (GComp tc t a b)             -- body
                                  (GCompCtxt tc t a b)
  | CLetStruct CompLoc (GStructDef t) (GCompCtxt tc t a b)

type CompCtxt = GCompCtxt CTy Ty () ()



inTyOfCTy   :: CTy0 -> Ty
inTyOfCTy (TComp _ x _) = x
inTyOfCTy (TTrans x _)  = x

yldTyOfCTy  :: CTy0 -> Ty
yldTyOfCTy (TComp _ _ x)  = x
yldTyOfCTy (TTrans _ x)   = x


inTyOfCTyBase :: CTy -> Ty
inTyOfCTyBase (CTBase ct) = inTyOfCTy ct
inTyOfCTyBase _ = error "inTyOfCTyBase: not a base type!"

yldTyOfCTyBase :: CTy -> Ty
yldTyOfCTyBase (CTBase ct) = yldTyOfCTy ct
yldTyOfCTyBase _ = error "yldTyOfCTyBase: not a base type!"

doneTyOfCTyBase :: CTy -> Maybe Ty
doneTyOfCTyBase (CTBase ct) = doneTyOfCTy ct
doneTyOfCTyBase _ = error "doneTyOfCTyBase: not a base type!"


isCTyBase :: CTy -> Bool
isCTyBase (CTBase {}) = True
isCTyBase _ = False


doneTyOfCTy :: CTy0 -> Maybe Ty
-- NOTE: transformers have no doneTy
doneTyOfCTy (TComp x _ _) = Just x
doneTyOfCTy (TTrans _ _) = Nothing

hasDoneTyBase :: CTy -> Bool
hasDoneTyBase (CTBase ct) = hasDoneTy ct
hasDoneTyBase _ = error "hasDoneTyBase: not a base type!"

hasDoneTy :: CTy0 -> Bool
hasDoneTy cty
  | Just _ <- doneTyOfCTy cty = True
  | otherwise                 = False

isCompCTy :: CTy0 -> Bool
isCompCTy (TComp {}) = True
isCompCTy _ = False


-- Composing transformers and computers
parCompose :: CTy -> CTy -> CTy
parCompose (CTBase (TTrans t1 _))
           (CTBase (TTrans _ t3))  = CTBase (TTrans t1 t3)
parCompose (CTBase (TTrans t1 _))
           (CTBase (TComp v _ t3)) = CTBase (TComp v t1 t3)
parCompose (CTBase (TComp v t1 _))
           (CTBase (TTrans _ t3))  = CTBase (TComp v t1 t3)
parCompose (CTBase (TComp v t1 _))
           (CTBase (TComp _ _ t3)) = CTBase (TComp v t1 t3)
parCompose _ct1 _cty2
  = error "Type checking bug: revealed in parCompose!"


toComp :: a -> GComp0 tc t a b -> GComp tc t a b
toComp a c0 = MkComp c0 Nothing a

toCompPos :: a -> SourcePos -> GComp0 tc t a b -> GComp tc t a b
toCompPos a pos c0 = MkComp c0 (Just pos) a




-- TODO: The cases for Repeat, VectComp, Interleave and Standalone look
-- suspicious? Why no +1? Fix or document.
compSize :: GComp tc t a b -> Int
compSize c = case unComp c of
  Var _nm                           -> 1
  BindMany c1 xs_cs                 -> foldr (\(_x,c') _s -> compSize c') (compSize c1) xs_cs
  Seq c1 c2                         -> 1 + compSize c1 + compSize c2
  Par _ c1 c2                       -> 1 + compSize c1 + compSize c2
  Let _nm c1 c2                     -> 1 + compSize c1 + compSize c2
  LetE _nm _ _e c1                  -> 2 + compSize c1
  LetERef _nm (Just _) c1           -> 2 + compSize c1
  LetERef _nm Nothing  c1           -> 2 + compSize c1
  LetHeader _f c1                   -> 2 + compSize c1
  LetStruct _sdef c1                -> 1 + compSize c1
  LetFunC _nm _params _locals c1 c2 -> 1 + compSize c1 + compSize c2
  Call _nm es                       -> 1 + sum (map callArgSize es)
  Emit _a _e                        -> 1
  Emits _ _e                        -> 1
  Return _ _ _ _e                   -> 1
  Branch _e c1 c2                   -> 1 + compSize c1 + compSize c2
  Take1 _ _                         -> 1
  Take _ _ _                        -> 1
  Until _e c1                       -> 1 + compSize c1
  While _e c1                       -> 1 + compSize c1
  Times _ui _e1 _e2 _nm c1          -> 1 + compSize c1
  Repeat _ c1                       -> compSize c1
  VectComp _ c1                     -> compSize c1
  Map _ _nm                         -> 1
  Filter _e                         -> 1
  Interleave c1 c2                  -> compSize c1 + compSize c2
  ReadSrc  {}                       -> 1
  WriteSnk {}                       -> 1
  ReadInternal  {}                  -> 1
  WriteInternal {}                  -> 1
  Standalone c1                     -> compSize c1
  Mitigate {}                       -> 1

callArgSize :: CallArg (GExp t b) (GComp tc t a b) -> Int
callArgSize (CAExp _)  = 0
callArgSize (CAComp _) = 1

{-------------------------------------------------------------------------------
  PrettyVal instances (used for dumping the AST)
-------------------------------------------------------------------------------}

instance PrettyVal ParInfo
instance PrettyVal PlInfo
instance PrettyVal ReadType
instance PrettyVal VectAnn

instance PrettyVal t => PrettyVal (GCTy0 t)
instance PrettyVal t => PrettyVal (GCTy t)

instance (PrettyVal a, PrettyVal b) => PrettyVal (CallArg a b)

instance (PrettyVal tc, PrettyVal t, PrettyVal a, PrettyVal b) => PrettyVal (GComp0 tc t a b)
instance (PrettyVal tc, PrettyVal t, PrettyVal a, PrettyVal b) => PrettyVal (GComp tc t a b)
instance (PrettyVal tc, PrettyVal t, PrettyVal a, PrettyVal b) => PrettyVal (GProg tc t a b)

-- Note [Standalone reads]
-- ~~~~~~~~~~~~~~~~~~~~~~~
--
-- Reads arising from standalone pipelining are slightly problematic.
-- Normally, if a read from a thread-separator cannot be executed because
-- the queue is empty we could return SKIP and jump to this threads main
-- control loop. That's all very fine.
--
-- *Except* when this thread is the main thread (i.e. /not/ a standalone).
-- Example:
--    main thread: read >>> c1 >>> write(s) >>> read(q) >>> c2 >>> write
--    standalone : read(s) >>> s >>> write(q)
--
-- If the 'read(q)' returns SKIP and jumps back to the main threads
-- loop, next time around we will ask again to read(q), which will
-- also be empty.  Our only chance of making progress, is to jump to
-- the *consume* continuation which is the consume continuation of the
-- write(s) which will eventually cause the 's' queue to be filled in,
-- give a chance to the standalone thread to write to 'q', and then
-- give a chance to the main thread to read(q) successfully!
--
--
-- Hence, we pass a flag down to ReadInternal that will allow us to choose
-- one of the two behaviours for reading.
--
-- TODO: We might want to revisit this design later, or even deprecate the
-- standalone pipelining which does not perform great anyway, but at the time
-- of the writing of this comment (10/01/2014), this is not done.
