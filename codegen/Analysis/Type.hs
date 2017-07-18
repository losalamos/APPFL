{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE LiberalTypeSynonyms #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE TypeOperators       #-}


module Analysis.Type where

import           Analysis.Language
import           PPrint

import           Data.Coerce         (coerce)
import           Data.Foldable       (fold)
import           Data.IntMap         (IntMap)
import qualified Data.IntMap         as IM
import           Data.Map            (Map)
import qualified Data.Map            as M
import           Data.Maybe          (fromMaybe)
import           Data.Set            (Set)
import qualified Data.Set            as S

import           Control.Monad.RWS
import           Control.Monad.State

import           Text.Show.Pretty
import           Debug.Trace

type Fact        = (ID, Type)
type Facts       = Map ID Type
type Assumption  = (ID, Type)
type Assumptions = Map ID [Type]
type Monotypes   = Set Type
type Constraints = Set Constraint
data Constraint
  = Type :=: Type -- Equivalence
  | Type :<: Type -- Explicit constraint
  | Impl (Set Type) Type Type -- Implicit constraint
  deriving (Show, Eq, Ord)

-- Constraint Generation State
data CGState = CGS { assumps :: Assumptions
                   , monotys :: Monotypes
                   , uniqMap :: IntMap Int
                   , nextInt :: Int
                   }


-- Constraint Generation Monad
type CGM = RWS Facts Constraints CGState


allNames = [c:cs | cs <- "" : allNames, c <- ['a'..'z']]

modifyAssums :: (Assumptions -> Assumptions) -> CGM ()
modifyMonotys :: (Monotypes -> Monotypes) -> CGM ()
modifyAssums f = modify $ \c -> c{assumps = f $ assumps c}
modifyMonotys f = modify $ \c -> c{monotys = f $ monotys c}

nextIntFor :: Int -> CGM Int
nextIntFor u = do
  umap <- gets uniqMap
  let i = fromMaybe 0 $ IM.lookup u umap
      m' = IM.insert u (i + 1) umap
  modify $ \c -> c{uniqMap = m'}
  return i

addGetAssum :: ID -> CGM Type
addGetAssum id@(ID name uniq) = do
  i <- nextIntFor uniq
  let ty = TVar $ 't': show i ++ '_' : showUniqName id
  modifyAssums $ M.insertWith (++) id [ty]
  return ty

withMonotypes mts act = do
  mtys <- gets monotys
  modifyMonotys (S.union (S.fromList mts))
  v <- act
  modifyMonotys (const mtys)
  pure v

freshTVar :: CGM Type
freshTVar = do
  i <- gets nextInt
  modify $ \c -> c{nextInt = nextInt c + 1}
  return $ TVar $ 'g':'t': show i -- generated type

removeAssums :: [ID] -> CGM ()
removeAssums bs = modifyAssums $ M.filterWithKey (\b _ -> not $ b `elem` bs)

getAllAssums :: [ID] -> CGM Assumptions
getAllAssums ids = gets $ M.filterWithKey (\k _ -> k `elem` ids) . assumps

type UT f a = Unique (Typed f) a

typecheck :: Unique Prog a ->
  ([UT ValDef a], [UT ValDef a], Sub)
typecheck (Prog (vdefs, ddefs)) =
  if M.null $ assumps endState
  then typed
  else  error $ "Assumptions aren't empty?\n" ++ show (assumps endState) ++
        '\n':show newVDefs
  where facts = M.unions $ map makeFacts ddefs
        newDDefs = map coerceDef ddefs
        coerceDef (DDef ty cons) = DDef ty (map coerce cons)
        initState = CGS M.empty S.empty IM.empty 0
        (newVDefs, endState, constraints) =
          runRWS (constrainVDefs vdefs) facts initState
        subst = solve constraints
        tprog = applyAll subst newVDefs
        tvars = map TVar allNames
        typed = (newVDefs, map (coVDef M.empty tvars) tprog, subst)

makeFacts :: Unique DataDef a -> Facts
makeFacts (DDef t@(TApp tcon vs) cons) = M.fromList $ map mkFact cons
  where mkFact (DCon id tys _) = (id, TForall vars $ foldr TFun t tys)
        vars = map (\case
                       TVar v -> v
                       _      -> error "DataDef type should be a simple TApp")
               vs
makeFacts _ = error "DataDef type should be a TApp type"


constrainVDefs :: [Unique ValDef a] -> CGM [Unique (Typed ValDef) a]
constrainVDefs defs = do
  newDefs <- mapM constrainVDef defs
  let newBinds = map binding newDefs
      newTypes = map vmeta newDefs
      tyMap = M.fromList $ zip newBinds newTypes

  monotys <- gets monotys

  -- All the assumptions about variables about to go out of scope
  localAssums <- getAllAssums newBinds

  -- Pair each of these assumptions (by ID) with the type set in their bound
  -- expressions for creating implicit constraints
  let constraints =
        constrainAssumsWith (flip (Impl monotys)) localAssums tyMap

  -- Add implicit constraints for each of the created pairs
  tell constraints

  -- Remove all assumptions about bindings about to leave scope
  removeAssums newBinds

  -- Now we're done, typed definitions can be returned
  pure newDefs


constrainVDef :: Unique ValDef a -> CGM (Unique (Typed ValDef) a)
constrainVDef (VDef name rhs _) = do
  -- Don't need to change assumptions or constraints here; just set the type and
  -- return the new VDef
  newRhs <- constrainExpr rhs
  pure $ VDef name newRhs (getType newRhs)


-- | Generate constraints/assumptions from an Expr type
constrainExpr :: Unique Expr a -> CGM (Unique (Typed Expr) a)
constrainExpr e = case e of
  Lit v _ -> pure $ Lit v (getType v)
  Var n _ -> do
    facts <- ask
    ty <- maybe (addGetAssum n) pure $ M.lookup n facts
    -- mapM (\fact -> tell . S.singleton $ ty :<: fact)
    pure (Var n ty)


  Lambda params body _ -> do
    mtys <- mapM addGetAssum params
    withMonotypes mtys $ do
      newBody <- constrainExpr body
      assums  <- getAllAssums params

      let resTy = getType newBody -- type of body
          lamTy = foldr TFun resTy mtys -- function type for this expression
          constraints = constrainAssumsWith (:=:) assums
                        (M.fromList $ zip params mtys)

      tell constraints
      removeAssums params
      pure $ Lambda params newBody lamTy

  CaseOf sce scb clas _ ->
    do
      newClas  <- mapM constrainClause clas
      newScrt  <- constrainExpr sce

      -- Assumptions about the scrutinee binding
      scAssums <- gets $ M.findWithDefault [] scb . assumps

      -- get the types of the patterns matched and the resulting expressions
      let (pTys, t0:eTys) = unzip $ map cmeta newClas
          -- The types of patterns and the assumed type of the scrutinee binding
          -- all have to be equivalent to the type of the scrutinee itself
          eqScrutTys      = scAssums ++ pTys
          constrs         = S.fromList (map (:=: getType newScrt) eqScrutTys)
                            `S.union`
                            -- All resulting expressions have to have the same
                            -- type, so add equivalence constraints between the
                            -- first type and every other
                            S.fromList (map (:=: t0) eTys)
      -- Add the constraints
      tell constrs
      -- Remove assumptions about scrutinee binding
      modify $ \c -> c{assumps = M.delete scb $ assumps c}
      -- The Case expression has the same type as that of the result
      -- expressions, so we can arbitrarily use the type of the first (which
      -- must always exist)
      pure $ CaseOf newScrt scb newClas t0

  Apply f e _ -> do
    newF <- constrainExpr f
    newE <- constrainExpr e
    atyp <- freshTVar -- We want to have a type for every expression, so make a
                      -- fresh one for the result of this application
    let constr = getType newF :=: TFun (getType newE) atyp
    tell $ S.singleton constr
    pure $ Apply newF newE atyp

  LetRec binds res _ -> do
    -- Important that we handle the result "before" the bindings so the
    -- assumptions generated therein are usable in the rule for the definitions
    newRes   <- constrainExpr res
    newBinds <- constrainVDefs binds

    -- All the real work is done in 'constrainVDefs', so we just set the type
    -- and move on
    pure $ LetRec newBinds newRes (getType newRes)


-- | Helper function for generating Constraints from Assumptions and a Map of
-- types inferred for some set of variables.  The Constraints generated are on
-- types associated only with variables that appear in both the Assumptions and
-- the Map.
constrainAssumsWith
  :: (Type -> Type -> Constraint) -- How to make a constraint
  -> Assumptions -- Assumptions about some variables
  -> Map ID Type -- Map of variable to "set" type
  -> Constraints -- Yields a Constraint Set
constrainAssumsWith comb assums tymap =
  S.fromList . concat . M.elems $
  M.intersectionWith (\t ts -> map (comb t) ts)
  tymap assums


-- | Generate assumptions and constrains about a Clause.
constrainClause :: Unique Clause a -> CGM (Unique (Typed Clause) a)
constrainClause c = case c of
  LitMatch lit consq _ -> do
    newConsq <- constrainExpr consq
    let ty = (getType lit, getType newConsq)
    pure $ LitMatch lit newConsq ty

  ConMatch con args consq _ ->
    let getFact facts = fromMaybe err $ M.lookup con facts
        err = error $ "Why isn't there a fact for " ++ show con
    in do
      fact     <- asks getFact
      newConsq <- constrainExpr consq
      assums   <- getAllAssums args
      argTys   <- mapM addGetAssum args
      let
        resTy   = finalResTy fact -- the 'T' in 'a -> b -> ... -> T'
        funTy   = foldr TFun resTy argTys
        constrs = S.insert (funTy :<: fact) $
          constrainAssumsWith (:=:) assums (M.fromList $ zip args argTys)

      -- Add constrants and remove assumptions about variables leaving scope
      tell constrs >> removeAssums args
      pure $ ConMatch con args newConsq (resTy, getType newConsq)

  Default consq _ -> do
    newConsq <- constrainExpr consq
    scTy     <- freshTVar
    pure $ Default newConsq (scTy, getType newConsq)


--------------------------------------------------------------------------------
-- Solving Constraints and generating Substitutions
--------------------------------------------------------------------------------

type Sub = Map Type Type

class Subst a where
  {-# MINIMAL (applyAll | applyOne) #-}
  applyAll :: Sub -> a -> a
  applyOne :: (Type, Type) -> a -> a
  -- Probably hugely inefficient for most substitutions
  applyAll subs v = foldr applyOne v $ M.toList subs

  -- This is probably reasonable, though building singleton maps across many
  -- calls will not be great.
  applyOne (s,d) v = applyAll (M.singleton s d) v


instance {-# OVERLAPPING #-}
  (Subst a, Ord a) => Subst (Set a) where
  applyOne s = S.map (applyOne s)
  applyAll s = S.map (applyAll s)

instance {-# OVERLAPPABLE #-}
  (Functor f, Subst a) => Subst (f a) where
  applyOne s = fmap (applyOne s)
  applyAll s = fmap (applyAll s)

instance Subst Type where
  applyOne s@(old, new) t
    | t == old = new
    | TFun t1 t2 <- t = TFun (applyOne s t1) (applyOne s t2)
    | TApp c ts  <- t = TApp c $ map (applyOne s) ts
    | TForall vs ty <- t,
      TVar v <- old,
      not $ v `elem` vs = TForall vs $ applyOne s ty
    | otherwise = t

  applyAll s t = fromMaybe t' $ M.lookup t s
    where t' =
            case t of
              TFun t1 t2 -> TFun (applyAll s t1) (applyAll s t2)
              TApp c ts  -> TApp c $ map (applyAll s) ts
              TForall vs ty -> TForall vs $ applyAll s' ty
                where s' = M.filter (\case
                                        TVar v -> not $ v `elem` vs
                                        _ -> True
                                    ) s
              -- TPrim and TVar are not recursive, so should be picked up in the
              -- initial lookup if they are to be substituted (unlikely for
              -- TPrim)
              _ -> t

-- We need to be able to apply substitutions to the unsolved constraints
instance Subst Constraint where
  applyOne s c = applyCnst applyOne s c
  applyAll s c = applyCnst applyAll s c

-- Substitution pattern for Constraints is simple delegation, but to abstract
-- it into a useful function requires a higher-rank type.
applyCnst :: (forall t . Subst t => s -> t -> t)
          -> s -> Constraint -> Constraint
applyCnst f s c = case c of
  t1 :=: t2 -> f s t1 :=: f s t2
  t1 :<: t2 -> f s t1 :<: f s t2
  Impl ms t1 t2 -> Impl (f s ms) (f s t1) (f s t2)


-- Get the free variables of a type.  Invariant: The returned Types are TVars
freevars :: Type -> Set Type
freevars t = case t of
  TVar v -> S.singleton t
  TPrim _ -> S.empty
  TApp _ ts -> S.unions $ map freevars ts
  TFun t1 t2 -> freevars t1 `S.union` freevars t2
  TForall vs t -> freevars t S.\\ (S.fromList $ map TVar vs)

-- Get the active variables in a Constraint.
activevars :: Constraint -> Set Type
activevars c = case c of
  t1 :=: t2 -> freevars t1 `S.union` freevars t2
  t1 :<: t2 -> freevars t1 `S.union` freevars t2
  Impl ms t1 t2 -> freevars t1 `S.union`
                   (fold (S.map freevars ms) `S.intersection`
                    freevars t2)

-- | mgu = "Most General Unification"
mgu :: Type -> Type -> Sub
-- We may get some constraints like this, particularly after substitutions, e.g.
--  TPrim PInt :=: TPrim PInt
mgu a b | a == b = M.empty
        | otherwise = go a b True
  where
    go a@TVar{} b@_ _
      | a `elem` freevars b = occursError a b
      | otherwise           = M.singleton a b
    go (TFun a1 a2) (TFun b1 b2) _ = mgu a1 b1 `compose` mgu a2 b2
    go (TApp ac as) (TApp bc bs) _
      | ac == bc && length as == length bs
      = foldr compose M.empty $ zipWith mgu as bs
    go _ _ firstTry
      -- If this is the first attempt, swap the types and retry
      | firstTry = go b a False
      -- Otherwise we're trying to unify non-equal types.  Note that TForall is
      -- not matched here, since it should never be passed as an argument.
      | otherwise = unifyError a b

unifyError a b = error $ unlines
  [ "Can't unify!"
  , show (unparse a) ++ " with " ++ show (unparse b)
  ]
occursError a b = error $ unlines
  [ "Occurs check failed!"
  , show (unparse a) ++ " found in " ++ show (unparse b)]


compose :: Sub -> Sub -> Sub
compose s1 s2 = M.map (applyAll s1) s2 `M.union` s1


instantiate :: Type -> Int -> (Type, Int)
instantiate (TForall vs t) i | null vs   = (t, i)
                             | otherwise = (ty, i + length vs)
  where ty = applyAll (M.fromList pairs) t
        pairs = zipWith mkPair [i..] vs
        mkPair i v = (TVar v, TVar $ v ++ '@' : show i)
instantiate t i = (t, i) -- shouldn't happen

generalize :: Set Type -> Type -> Type
generalize ms t = TForall vs t
  where vs = foldr getVars [] $ freevars t S.\\ fold (S.map freevars ms)
        getVars (TVar v) l = v : l
        getVars _        l = l

solve :: Constraints -> Sub
solve c = go (S.toList c) [] True 0 M.empty
  where go [] [] _ _ sub = sub
        go [] ds retry i sub
          | retry = go ds [] False i sub
          | otherwise = error $ "Can't make progress with " ++ show ds
        go (c:cs) ds retry i sub = case c of
          t1 :=: t2 -> go cs' ds' True i sub'
            where sub' = mgu t1 t2 `compose` sub
                  cs' = applyAll sub' cs
                  ds' = applyAll sub' ds
          t1 :<: t2 -> let (t', i') = instantiate t2 i
                           in go (t1:=:t':cs) ds True i' sub
          Impl ms t1 t2
            | freePoly1 <- freevars t2 S.\\ ms,
              freePoly2 <- S.unions $ map activevars cs,
              null $ freePoly1 `S.intersection` freePoly2
              -> go (t1 :<: generalize ms t2 : cs) ds True i sub
            | otherwise
              -> go cs (c:ds) retry i sub

-- | /fixing/ the Substitution seemed like it might be necessary at first, but I
-- think now it can be used as a sanity check.  If the Substitution resulting
-- from solving Constraints can be reduced with this function, something has
-- probably gone wrong.
fixSub :: Sub -> Sub
fixSub s = go s (M.map (applyAll s) s)
  where go s1 s2 | s1 == s2 = s1
                 | otherwise = go s2 (M.map (applyAll s2) s2)


-- A substitution can be applied to every level of the AST:
instance Subst (Typed ValDef a) where
  applyAll s (VDef id e t) = VDef id (applyAll s e) (applyAll s t)

instance Subst (Typed Expr a) where
  applyAll s e = case e of
    Lit l t -> Lit l (applyAll s t)
    Var n t -> Var n (applyAll s t)
    Lambda ps e t
      -> Lambda ps (applyAll s e) (applyAll s t)
    CaseOf se sb cs e
      -> CaseOf (applyAll s se) sb (applyAll s cs) (applyAll s e)
    LetRec ds e t
      -> LetRec (applyAll s ds) (applyAll s e) (applyAll s t)
    Apply f e t
      -> Apply (applyAll s f) (applyAll s e) (applyAll s t)

instance Subst (Typed Clause a) where
  applyAll s c = case c of
    LitMatch p c (tp, tc)
      -> LitMatch p (applyAll s c) (applyAll s tp, applyAll s tc)
    ConMatch p as c (tp, tc)
      -> ConMatch p as (applyAll s c) (applyAll s tp, applyAll s tc)
    Default c (tp, tc)
      -> Default (applyAll s c) (applyAll s tp, applyAll s tc)


traceWith :: (a -> String) -> a -> a
traceWith f b = trace (f b) b



--------------------------------------------------------------------------------
-- | Closing over type variables
--
-- As In the 'CO' typeclass from HMStg.hs, we want to make it explicit where
-- polymorphic types lie (using 'TForAll') and use that to introduce type
-- variable scope.  That is, there should never be a type in the AST with type
-- variable not quantified at some higher scope.  After constraints are solved
-- and the resulting types are assigned, this is /not/ the case: polymorphic
-- types are implicit, hence this operation.
--
-- This also renames type variable for better readability.


coVDef :: Sub -> [Type]-> Typed ValDef a -> Typed ValDef a
coVDef bvs unused (VDef id e _) = VDef id newExp ty
  where newExp = coExpr bvs unused e
        ty     = getType newExp



coExpr :: Sub -> [Type] -> Typed Expr a -> Typed Expr a
coExpr bmap unused e =
  let
    unpack (TVar v) = v
    unpack t = error $ "Set of freevars should only be TVars: " ++ show t
    open = S.toList $ freevars (getType e) S.\\ M.keysSet bmap
    (ozipped, rem) = zipRem open unused
    tvs = map (unpack . snd) ozipped
    newBmap = M.union bmap $ M.fromList ozipped
    renamed = applyAll newBmap $ getType e
    newTy = case open of
      [] -> renamed
      _  -> TForall tvs renamed

  in case e of
    Lit v _ -> Lit v newTy
    Var n _ -> Var n newTy
    Lambda ps body _ -> Lambda ps (coExpr newBmap rem body) newTy
    CaseOf sce scb cls _ -> let scrut = coExpr newBmap rem sce
                                clsTy  = (getType scrut, newTy)
                            in CaseOf scrut scb (map (coClause newBmap rem clsTy) cls) newTy
    Apply f e _ -> Apply (coExpr newBmap rem f) (coExpr newBmap rem e) newTy
    LetRec binds res _ -> LetRec (map (coVDef newBmap rem) binds) (coExpr newBmap rem res) newTy

coClause :: Sub -> [Type] -> (Type, Type) -> Typed Clause a -> Typed Clause a
coClause bvs unused clsTy c = case c of
  LitMatch l e _ -> LitMatch l (coExpr bvs unused e) clsTy
  Default e _ -> Default (coExpr bvs unused e) clsTy
  ConMatch c vs e _ -> ConMatch c vs (coExpr bvs unused e) clsTy


zipRem :: [a] -> [b] -> ([(a,b)], [b])
zipRem [] bs = ([], bs)
zipRem as [] = error "zipRem: 'as' longer than 'bs'"
zipRem (a:as) (b:bs) = let (l, rem) = zipRem as bs
                       in ((a,b) : l, rem)