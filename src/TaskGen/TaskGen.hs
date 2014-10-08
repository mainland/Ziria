{-# LANGUAGE GADTs, EmptyDataDecls, MultiParamTypeClasses, FlexibleInstances #-}
-- | Rewrite an optimized, renamed and generally mangled AST
--   into an AST utilizing the new fancy scheduler.
module TaskGen (
    insertTasks
  ) where
import Control.Applicative
import Control.Monad.State
import qualified Data.Set as S

import AstComp hiding (comp)
import AstExpr hiding (name, info)
import Outputable
import TaskGenTypes
import TaskGenMonad

-- | Comp representing the starting of a task.
startTask :: Comp CTy Ty -> TaskID -> Comp CTy Ty
**************************
DV: change this to the following signature, to emphasize that startTask does not do anything with the comp:
startTask :: Maybe SrcLoc -> CTy -> TaskId -> Comp CTy TY 
startTask c t = MkComp (ActivateTask t Nothing) (compLoc c) (compUnitTy c)

**** same comment applies here as for startTask: 
-- | Comp representing the starting of a task from a 'BindMany', with an input var.
startTaskWithInVar :: Name -> Comp CTy Ty -> TaskID -> Comp CTy Ty
startTaskWithInVar v c t = MkComp (ActivateTask t (Just v)) (compLoc c) (compUnitTy c)

-- | Split program into entry points and tasks to be started along the road.
--   TODO: task map needs more info.
insertTasks :: Comp CTy Ty -> (TaskEnv, Comp CTy Ty)
insertTasks = runTaskGen . go
  where
    go comp = do
      let errq = error "Queue is not supposed to be used!" 
      tid <- taskify (errq, errq) Nothing comp
      taskComp <$> lookupTask tid

-- | Given an expression of type Comp a i o, produces a type Comp () i o.
compUnitTy :: Comp CTy Ty -> CTy
compUnitTy c =
  case compInfo c of
    (CTBase (TComp _ i o)) -> CTBase $ TComp TUnit i o
    (CTBase (TTrans i o))  -> CTBase $ TComp TUnit i o
    _                      -> error $ "Non base type in compUnitTy:\n" ++ show (ppr $ compInfo c)

-- | The type Comp (C ()) () ().
compTripleUnitTy :: CTy
compTripleUnitTy = CTBase $ TComp TUnit TUnit TUnit

-- | Split the given AST along task barriers. The returned task is the entry
--   point of the program, from which further tasks are spawned as needed.
--   In the absence of `standalone` annotations, this generates a single
--   task containing the entirety of the program.
--
--   Currently, only 'Standalone' creates a primitive barrier. |>>>| is treated
--   like >>>.
--
--   TODO: the compInfo stuff (the types) are probably incorrect for parts.
--
--   TODO: current algorithm, calling containsBarrier all over the place, is
--         O(n^2) - could be O(n) if we instead annotated the AST as we
--         traverse it.
--
--   TODO: currently doesn't do synchronization at start/end of tasks.
--
--   TODO: currently doesn't calculate cardinalities for commit queues.
--
--   TODO: don't generate unnecessary queues or their associated reads/writes.
--         they don't really do anything so it's not incorrect per se to generate
--         them, but it's ugly.
--
--
--   TODO:  Change the Maybe (Comp CTy Ty) to something that more explicitly records if t
--          this continuation has been taskified or not. E.g. a TaskId or maybe if we need
--          to also emit code about waiting someone else then another TaskId. In general
--          something like:   SynchronizationInfo  (who to start next and who to wait for etc)
-- 
taskify :: (Queue, Queue)
        -> Maybe (Comp CTy Ty)  
        -> Comp CTy Ty
        -> TaskGen TaskID TaskInfo TaskID
taskify qs@(inq, outq) mnxt c = do
    case (containsBarrier c, mnxt) of
      (True, _)         -> go (unComp c)
      (False, Just nxt)
        | isComputer c  -> createTask (MkComp (c `Seq` nxt) (compLoc c) (compInfo c)) qs
      _                 -> createTask c qs
  where
    -- Invariant: if go gets called, its argument *does* contain a barrier.
    -- It's important to note that sequential code is generated right to left,
    -- in order to ensure that each sequential computation always knows its
    -- continuation.
    -- TODO: sync code here!
    go :: Comp0 CTy Ty -> TaskGen TaskID TaskInfo TaskID
    go (BindMany first rest)
      | containsBarrier first = do
          let ((v, comp):xs) = rest
          ms <- taskify qs mnxt (MkComp (BindMany comp xs) (compLoc comp) (compInfo c))
          tid <- taskify qs (Just $ startTaskWithInVar v c ms) first
          createTask (startTask first tid) qs
      | otherwise = do
          comp <- genBindManyBarriers first (splitBarriers rest)
          createTask comp qs
      where
        -- Invariant: each (first ++ b) contains a barrier.
        genBindManyBarriers :: Comp CTy Ty -> [[(Name, Comp CTy Ty)]] -> TaskGen TaskID TaskInfo (Comp CTy Ty)
        genBindManyBarriers frst (b:bs) = do
          case bs of
            (((_, first'):rest'):bs') -> do
              -- Next task is just the next in the list of barriers
              nxt <- Just <$> genBindManyBarriers first' (rest':bs')
              b' <- taskify qs nxt $ MkComp (BindMany frst b) (compLoc frst) (compInfo c)
              startTask c <$> createTask (startTask c b') qs
            _                        -> do
              -- End of bind; next task is whatever came from the outside, if any
              b' <- taskify qs mnxt $ MkComp (BindMany first b) (compLoc first) (compInfo c)
              startTask c <$> createTask (startTask c b') qs
        genBindManyBarriers _ [] = do
          error "BUG: barrier is in first comp of BindMany, but genBindManyBarriers was called!"

    go (Seq _ _) = do
      mcomp <- foldM seqStart mnxt (reverse $ findBarriers c)
      case mcomp of
        Just comp -> createTask comp qs
        _         -> error "The impossible happened!"
      where
        -- TODO: some more sync code should go here!
        seqStart :: Maybe (Comp CTy Ty) -> Comp CTy Ty -> TaskGen TaskID TaskInfo (Maybe (Comp CTy Ty))
        seqStart (Just next) comp = do
          startNext <- startTask next <$> createTask next qs
          Just <$> taskify qs (Just startNext) comp
        seqStart Nothing comp = do
          Just <$> taskify qs Nothing comp

        -- Turn a ; standalone b ; c ; d into [a, standalone b, c ; d]
        findBarriers :: Comp CTy Ty -> [Comp CTy Ty]
        findBarriers s@(MkComp (Seq l r) _ _) =
          case (containsBarrier l, containsBarrier r) of
            (True, True)  -> findBarriers l ++ findBarriers r
            (True, False) -> findBarriers l ++ [r]
            (False, True) -> l:findBarriers r
            _             -> [s]
        findBarriers s = [s]

    go (Par _ _ _) = do
      -- TODO: find first and last components of pipeline, as well as the computer (if any) and add sync
      --       code! Also, commit queues; currently everything is simple queues.
      let bars = findBarriers c
      queues <- mapM (const freshQueue) (drop 1 bars)
      taskIds <- mapM createTask' $ zip3 bars (inq:queues) (queues ++ [outq])
      let starts = foldr1 (cSeq (compLoc c) compTripleUnitTy) $
                     zipWith startTask bars taskIds
      createTask starts (head queues, last queues)
      where
        createTask' (c', qin', qout') = taskify (qin', qout') mnxt c'

        -- Turn a >>> standalone b >>> c >>> d into [a, standalone b, c >>> d]
        findBarriers p@(MkComp (Par _ l r) _ _) =
          case (containsBarrier l, containsBarrier r) of
            (True, True)  -> findBarriers l ++ findBarriers r
            (True, False) -> findBarriers l ++ [r]
            (False, True) -> l:findBarriers r
            _             -> [p]
        findBarriers p = [p]

    -- Let bindings will be declared on the top level, so we keep them around
    -- in the AST just to have their values properly assigned.
    go (Let name rhs comp) = do
      tid <- taskify qs mnxt comp
      updateTaskComp tid $ \c' ->
        MkComp (Let name rhs c') (compLoc c) (compInfo c)
      return tid
    go (LetE name inl rhs comp) = do
      tid <- taskify qs mnxt comp
      updateTaskComp tid $ \c' ->
        MkComp (LetE name inl rhs c') (compLoc c) (compInfo c)
      return tid
    go (LetERef name ty rhs comp)  = do
      tid <- taskify qs mnxt comp
      updateTaskComp tid $ \c' ->
        MkComp (LetERef name ty rhs c') (compLoc c) (compInfo c)
      return tid

    go (LetFunC name args locs body comp) = do
      -- We don't go into the body of the function since we simply can't split
      -- non-inlined functions into tasks.
      when (containsBarrier body) $ do
        addBarrierFun name
      tid <- taskify qs mnxt comp
      updateTaskComp tid $ \c' ->
        MkComp (LetFunC name args locs body c') (compLoc c) (compInfo c)
      return tid

    go (Interleave _ _) =
      error "BUG: Interleave in AST!"
    go (Branch cond th el) = do
      th' <- startTask th <$> taskify qs mnxt th
      el' <- startTask el <$> taskify qs mnxt el
      createTask (MkComp (Branch cond th' el') (compLoc c) (compInfo c)) qs
    go (Until _cond _comp) = do
      error "TODO: until requires some extra code"
    go (While _cond _comp) = do
      error "TODO: while requires some extra code"
    go (Times _ui _from _to _it _comp) = do
      error "TODO: times requires some extra code"
    go (AstComp.Repeat _mvect _comp) = do
      error "TODO: repeat requires some extra code"
    go (VectComp vect comp) = do
      -- TODO: cardinality information needed to inform the counting
      --       not necessarily right here though?
      tid <- taskify qs mnxt comp
      updateTaskComp tid $ \comp' ->
        MkComp (VectComp vect comp') (compLoc c) (compInfo c)
      return tid
    go (Standalone comp)
      | containsBarrier comp = do
        -- If we run into nested barriers, only the innermost level is
        -- honored. Maybe warn about this?
        taskify qs mnxt comp
      | otherwise = do
        let c' = case (isComputer c, mnxt) of
                   (True, Just nxt) -> MkComp (c `Seq` nxt) (compLoc c) (compInfo c)
                   _                -> c
        createTaskWithPlacement Alone c' qs
    -- If we get to either Map or Call, then the name they're calling on
    -- is a barrier for sure; make this a primitive barrier since we can't
    -- split funs.
    go (Map _ _) = do
        let c' = case (isComputer c, mnxt) of
                   (True, Just nxt) -> MkComp (c `Seq` nxt) (compLoc c) (compInfo c)
                   _                -> c
        createTaskWithPlacement Alone c' qs
    go (Call _ _) = do
        let c' = case (isComputer c, mnxt) of
                   (True, Just nxt) -> MkComp (c `Seq` nxt) (compLoc c) (compInfo c)
                   _                -> c
        createTaskWithPlacement Alone c' qs
    go _ = error "Atomic computations can't possibly contain barriers!"

-- | Split a list of computations, with an extra piece of information,
--   along task barrier lines.
splitBarriers :: [(a, Comp CTy Ty)] -> [[(a, Comp CTy Ty)]]
splitBarriers cs =
  case break (containsBarrier . snd) cs of
    (front, (barrier:back)) -> front : [barrier] : splitBarriers back
    (front, [])             -> [front]

-- | Does the given computation contain a task barrier?
--   Essentially, does it have a standalone subtree?
containsBarrier :: Comp CTy Ty -> Bool
containsBarrier = containsBarrier' S.empty
  where
    containsBarrier' barriers = go . unComp
      where
        go (BindMany first rest) =
          any (containsBarrier' barriers) (first : map snd rest)
        go (Seq left right) =
          containsBarrier' barriers left || containsBarrier' barriers right
        go (Par _ left right) =
          containsBarrier' barriers left || containsBarrier' barriers right
        go (Let _ _rhs comp) =
          containsBarrier' barriers comp
        go (LetE _ _ _ comp) =
          containsBarrier' barriers comp
        go (LetERef _ _ _ comp) =
          containsBarrier' barriers comp
        go (LetFunC name _ _ body comp) =
          if containsBarrier' barriers body
            then containsBarrier' (S.insert name barriers) comp
            else containsBarrier' barriers comp
        go (Interleave left right) =
          containsBarrier' barriers left || containsBarrier' barriers right
        go (Branch _ th el) =
          containsBarrier' barriers th || containsBarrier' barriers el
        go (Until _ comp) =
          containsBarrier' barriers comp
        go (While _ comp) =
          containsBarrier' barriers comp
        go (Times _ _ _ _ comp) =
          containsBarrier' barriers comp
        go (AstComp.Repeat _ comp) =
          containsBarrier' barriers comp
        go (VectComp _ comp) =
          containsBarrier' barriers comp
        go (Call n _) =
          n `S.member` barriers
        go (Map _ n) =
          n `S.member` barriers
        go (Standalone _) =
          True
        go _ =
          False