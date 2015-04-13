{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TypeFamilies #-}
module CompositionalLC
    ( inference
    , composeSubst
    , subst
    , freeVars
    ) where

import Data.Function
import Data.List
import Data.Maybe
import Data.Foldable (Foldable, foldMap, toList)
import qualified Data.Traversable as T
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Control.Applicative
import Control.Monad.Except
import Control.Monad.State
import Control.Monad.RWS
import Control.Monad.Writer
import Control.Arrow

import Type
import Typing


class FreeVars a where freeVars :: a -> Set TName

instance FreeVars Ty where
    freeVars (TVar _ a) = Set.singleton a
    freeVars (Ty x) = foldMap freeVars x

instance FreeVars a => FreeVars [a]                 where freeVars = foldMap freeVars
instance FreeVars a => FreeVars (Typing_ a)         where freeVars = foldMap freeVars
instance FreeVars a => FreeVars (TypeFun a)         where freeVars = foldMap freeVars
instance FreeVars a => FreeVars (MonoEnv a)         where freeVars = foldMap freeVars
instance FreeVars a => FreeVars (Constraint a)      where freeVars = foldMap freeVars


class Substitute a where subst :: Subst -> a -> a

instance Substitute Ty where
    subst st ty | Map.null st = ty -- optimization
    subst st tv@(TVar _ a) = fromMaybe tv $ Map.lookup a st
    subst st (Ty t) = Ty $ subst st <$> t

instance Substitute a => Substitute [a]                 where subst = fmap . subst
instance Substitute a => Substitute (Typing_ a)         where subst = fmap . subst
instance Substitute a => Substitute (MonoEnv a)         where subst = fmap . subst
instance Substitute a => Substitute (Constraint a)      where subst = fmap . subst


-- Note: domain of substitutions is disjunct
composeSubst :: Subst -> Subst -> Subst
s1 `composeSubst` s2 = s2 <> (subst s2 <$> s1)

-- unify each types in the sublists
unifyTypes :: Bool -> [[Ty]] -> TCM Subst
unifyTypes bidirectional xss = flip execStateT mempty $ forM_ xss $ \xs -> sequence_ $ zipWith uni xs $ tail xs
  where
    uni :: Ty -> Ty -> StateT Subst TCM ()
    uni a b = gets subst1 >>= \f -> unifyTy (f a) (f b)
      where
        subst1 s tv@(TVar _ a) = fromMaybe tv $ Map.lookup a s
        subst1 _ t = t

        singSubst n t (TVar _ a) | a == n = t
        singSubst n t (Ty ty) = Ty $ singSubst n t <$> ty

        -- make single tvar substitution; check infinite types
        bindVar n t = do
            s <- get
            let t' = subst s t
            if n `Set.member` freeVars t
                then lift $ throwErrorTCM $ "Infinite type, type variable " ++ n ++ " occurs in " ++ show t
                else put $ Map.insert n t' $ singSubst n t' <$> s

        unifyTy :: Ty -> Ty -> StateT Subst TCM ()
        unifyTy (TVar _ u) (TVar _ v) | u == v = return ()
        unifyTy (TVar _ u) _ = bindVar u b
        unifyTy _ (TVar _ u) | bidirectional = bindVar u a
        unifyTy (TTuple f1 t1) (TTuple f2 t2) = sequence_ $ zipWith uni t1 t2
        unifyTy (TCon f1 n1 t1) (TCon f2 n2 t2) | n1 == n2 = sequence_ $ zipWith uni t1 t2
        unifyTy (TArr a1 b1) (TArr a2 b2) = uni a1 a2 >> uni b1 b2
        unifyTy (TVec a1 b1) (TVec a2 b2) | a1 == a2 = uni b1 b2
        unifyTy (TMat a1 b1 c1) (TMat a2 b2 c2) | a1 == a2 && b1 == b2 = uni c1 c2
        unifyTy (TPrimitiveStream f1 a1 b1 g1 c1) (TPrimitiveStream f2 a2 b2 g2 c2) = uni a1 a2 >> uni b1 b2 >> uni c1 c2
        unifyTy a b
          | a == b = return ()
          | otherwise = lift $ throwErrorTCM $ "can not unify " ++ show a ++ " with " ++ show b

unifyTypings = unifyTypings_ True

unifyTypings_
    :: (NewVar a, NewVarRes a ~ Typing)
    => Bool         -- bidirectional unification
    -> [[Typing]]   -- unify each group
    -> ([Ty] -> a)  -- main typing types for each unified group -> result typing
    -> TCM (Subst, Typing)
unifyTypings_ bidirectional ts f = do
    t <- newV $ f $ map (typingType . head) ts
    let ms = map monoEnv $ t: concat ts
    s <- unifyTypes bidirectional $ (map . map) typingType ts ++ unifyMaps ms
    (s, i) <- untilNoUnif s $ nub $ subst s $ concatMap constraints $ t: concat ts
    let ty = Typing (Map.unions $ subst s ms) i (subst s $ typingType t)
    ambiguityCheck ty
    return (s, ty)
  where
    groupByFst :: Ord a => [(a, b)] -> [[b]]
    groupByFst = unifyMaps . map (uncurry Map.singleton)

    untilNoUnif acc es = do
        (es, w) <- runWriterT $ do
            -- unify left hand sides where the right hand side is equal:  (t1 ~ F a, t2 ~ F a)  -->  t1 ~ t2
            tell $ groupByFst [(f, ty) | CEq ty f <- es]
            -- injectivity test:  (t ~ Vec a1 b1, t ~ Vec a2 b2)  -->  a1 ~ a2, b1 ~ b2
            tell $ concatMap (concatMap transpose . groupByFst) $ groupByFst [(ty, (it, is)) | CEq ty (injType -> Just (it, is)) <- es]
            concat <$> mapM reduceConstraint es
        s <- unifyTypes True w
        if Map.null s then return (acc, es) else untilNoUnif (acc `composeSubst` s) $ nub $ subst s es

-- Ambiguous: (Int ~ F a) => Int
-- Not ambiguous: (Show a, a ~ F b) => b
ambiguityCheck :: Typing -> TCM ()
ambiguityCheck ty = do
    e <- errorTCM
    let c = if used `Set.isSubsetOf` defined then Nothing else Just $ e <> \_ -> unlines
            ["ambiguous type: " ++ show ty, "defined vars: " ++ show defined, "used vars: " ++ show used]
    modify $ (c:) *** id
  where
    used = freeVars $ constraints ty
    defined = dependentVars (constraints ty) $ freeVars (monoEnv ty) <> freeVars (typingType ty)

-- complex example:
--      forall b y {-monomorph vars-} . (b ~ F y) => b ->      -- monoenv & monomorph part of instenv
--      forall a x {-polymorph vars-} . (Num a, a ~ F x) => a  -- type & polymorph part of instenv
instantiateTyping :: Typing -> TCM (Subst, Typing)
instantiateTyping ty = do
    let fv = dependentVars (constraints ty) $ freeVars (typingType ty)  -- TODO: make it more precise if necessary
    newVars <- replicateM (Set.size fv) (newVar C)
    let s = Map.fromDistinctAscList $ zip (Set.toList fv) newVars
    return (s, subst s ty)

-- compute dependent type vars in constraints
-- Example:  dependentVars [(a, b) ~ F b c, d ~ F e] [c] == [a,b,c]
dependentVars :: [Constraint Ty] -> Set TName -> Set TName
dependentVars ie s = cycle mempty s
  where
    cycle acc s
        | Set.null s = acc
        | otherwise = cycle (acc <> s) (grow s Set.\\ acc)

    grow = flip foldMap ie $ \case
        CEq ty f -> freeVars ty <-> freeVars f
        Split a b c -> freeVars a <-> (freeVars b <> freeVars c)
        CUnify{} -> error "dependentVars: impossible" 
        CClass{} -> mempty
      where
        a --> b = \s -> if Set.null $ a `Set.intersection` s then mempty else b
        a <-> b = (a --> b) <> (b --> a)


inference :: Exp Range -> Either ErrorMsg (Exp (Subst, Typing))
inference e = runExcept $ fst <$>
    evalRWST (inferTyping e <* checkUnambError) (PolyEnv $ fmap ((,) mempty) <$> primFunMap, mempty) (mempty, 0)

removeMonoVars vs (Typing me cs t) = Typing (foldr Map.delete me $ Set.toList vs) cs t

inferTyping :: Exp Range -> TCM (Exp (Subst, Typing))
inferTyping exp = local (id *** const [getTag exp]) $ case exp of
    ELam _ p f -> do
        p_@(p, tr) <- inferPatTyping False p
        tf <- withTyping tr $ inferTyping f
        ty <- unifyTypings [getTagP' p_, getTag' tf] $ \[a, t] -> a ~> t
        return $ ELam (id *** removeMonoVars (Map.keysSet tr) $ ty) p tf
    ELet _ p x e -> do
        tx <- inferTyping x
        p_@(p, tr) <- inferPatTyping True p
        (s, _) <- unifyTypings [getTagP' p_ ++ getTag' tx] $ \[te] -> te
        te <- withTyping (subst s tr) $ inferTyping e
        return $ ELet (s, head $ getTag' te) p tx te
    ECase _ e cs -> do
        te <- inferTyping e
        cs <- forM cs $ \(p, exp) -> do
            (p, tr) <- inferPatTyping False p
            exp <- withTyping tr $ inferTyping exp
            return (p, exp)
        ty <- unifyTypings [getTag' te ++ concatMap getTagP' cs, concatMap (getTag' . snd) cs] $ \[_, x] -> x
        return $ ECase ty te cs
    Exp e -> do
        e' <- T.mapM inferTyping e
        Exp . (\t -> setTag undefined t e') <$> case e' of
            EApp_ _ tf ta -> unifyTypings [getTag' tf, getTag' ta] $ \[tf, ta] v -> [tf ~~~ ta ~> v] ==> v
            EFieldProj_ _ fn -> noSubst $ fieldProjType fn
            ERecord_ _ (unzip -> (fs, es)) -> unifyTypings (map getTag' es) $ TRecord . Map.fromList . zip fs
            ETuple_ _ te -> unifyTypings (map (getTag') te) $ TTuple C
            ELit_ _ l -> noSubst $ inferLit l
            EVar_ _ n -> asks (getPolyEnv . fst) >>= fromMaybe (throwErrorTCM $ "Variable " ++ n ++ " is not in scope.") . Map.lookup n
            ETyping_ _ e ty -> unifyTypings_ False [getTag' e ++ [ty]] $ \[ty] -> ty
  where
    inferPatTyping :: Bool -> Pat Range -> TCM (Pat (Subst, Typing), Map EName Typing)
    inferPatTyping polymorph p_@(Pat p) = local (id *** const [getTagP p_]) $ do
        p' <- T.mapM (inferPatTyping polymorph) p
        (t, tr) <- case p' of
            PLit_ _ n -> noTr $ noSubst $ inferLit n
            Wildcard_ _ -> noTr $ noSubst $ newV $ \t -> t :: Ty
            PVar_ _ n -> addTr (\t -> Map.singleton n (snd t)) $ noSubst $ newV $ \t ->
                if polymorph then [] ==> t else Typing (Map.singleton n t) mempty t :: Typing
            PTuple_ _ ps -> noTr $ unifyTypings (map getTagP' ps) (TTuple C)
            PCon_ _ n ps -> noTr $ do
                (_, tn) <- asks (getPolyEnv . fst) >>= fromMaybe (throwErrorTCM $ "Constructor " ++ n ++ " is not in scope.") . Map.lookup n
                unifyTypings ([tn]: map getTagP' ps) (\(tn: tl) v -> [tn ~~~ tl ~~> v] ==> v)
            PRecord_ _ (unzip -> (fs, ps)) -> noTr $ unifyTypings (map getTagP' ps)
                (\tl v v' -> [Split v v' $ TRecord $ Map.fromList $ zip fs tl] ==> v)
        let trs = Map.unionsWith (++) . map ((:[]) <$>) $ tr: map snd (toList p')
        tr <- case filter ((>1) . length . snd) $ Map.toList trs of
            [] -> return $ Map.map head trs
            ns -> throwErrorTCM $ "conflicting definitions for " ++ show (map fst ns)
        return (Pat $ setTagP t $ fst <$> p', tr)

    getTag' = (:[]) . snd . getTag
    getTagP' = (:[]) . snd . getTagP . fst
    noSubst = fmap ((,) mempty)
    noTr = addTr $ const mempty
    addTr tr m = (\x -> (x, tr x)) <$> m

withTyping :: Map EName Typing -> TCM a -> TCM a
withTyping ts m = do
    penv <- asks $ getPolyEnv . fst
    case toList $ Map.keysSet ts `Set.intersection` Map.keysSet penv of
        [] -> local ((<> PolyEnv (Map.map instantiateTyping ts)) *** id) m
        ks -> throwErrorTCM $ "Variable name clash: " ++ show ks

