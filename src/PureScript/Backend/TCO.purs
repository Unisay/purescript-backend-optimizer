module PureScript.Backend.TCO where

import Prelude

import Data.Array as Array
import Data.Array.NonEmpty as NonEmptyArray
import Data.Foldable (class Foldable, foldMap, foldr)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Newtype (class Newtype, unwrap)
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..), fst, snd, uncurry)
import PureScript.Backend.Semantics (NeutralExpr(..))
import PureScript.Backend.Syntax (BackendSyntax(..), Level, Pair(..))
import PureScript.CoreFn (Ident, Qualified)

newtype Call = Call
  { count :: Int
  , arities :: Set Int
  }

instance Semigroup Call where
  append (Call a) (Call b) = Call
    { count: a.count + b.count
    , arities: Set.union a.arities b.arities
    }

data TcoOptimization
  = TcoRecGroup
  | TcoNonRecTransitive

newtype TcoAnalysis = TcoAnalysis
  { calls :: Map (Tuple (Maybe Ident) Level) Call
  , tailCalls :: Map (Tuple (Maybe Ident) Level) Int
  , topLevelCalls :: Map (Qualified Ident) Call
  , topLevelTailCalls :: Map (Qualified Ident) Int
  , isTcoBinding :: Boolean
  }

derive instance Newtype TcoAnalysis _

instance Semigroup TcoAnalysis where
  append (TcoAnalysis a) (TcoAnalysis b) = TcoAnalysis
    { calls: Map.unionWith append a.calls b.calls
    , tailCalls: Map.unionWith add a.tailCalls b.tailCalls
    , topLevelCalls: Map.unionWith append a.topLevelCalls b.topLevelCalls
    , topLevelTailCalls: Map.unionWith add a.topLevelTailCalls b.topLevelTailCalls
    , isTcoBinding: false
    }

instance Monoid TcoAnalysis where
  mempty = TcoAnalysis
    { calls: Map.empty
    , tailCalls: Map.empty
    , topLevelCalls: Map.empty
    , topLevelTailCalls: Map.empty
    , isTcoBinding: false
    }

data TcoExpr = TcoExpr TcoAnalysis (BackendSyntax TcoExpr)

unTcoExpr :: TcoExpr -> BackendSyntax TcoExpr
unTcoExpr (TcoExpr _ a) = a

tcoAnalysisOf :: TcoExpr -> TcoAnalysis
tcoAnalysisOf (TcoExpr a _) = a

overTcoAnalysis :: (TcoAnalysis -> TcoAnalysis) -> TcoExpr -> TcoExpr
overTcoAnalysis f (TcoExpr a b) = TcoExpr (f a) b

tcoBound :: forall f. Foldable f => f (Tuple (Maybe Ident) Level) -> TcoAnalysis -> TcoAnalysis
tcoBound idents (TcoAnalysis s) = TcoAnalysis s
  { calls = foldr Map.delete s.calls idents
  , tailCalls = foldr Map.delete s.tailCalls idents
  }

tcoCall :: Tuple (Maybe Ident) Level -> Int -> TcoAnalysis -> TcoAnalysis
tcoCall ident arity (TcoAnalysis s) = TcoAnalysis s
  { calls = Map.insertWith append ident (Call { count: 1, arities: Set.singleton arity }) s.calls
  , tailCalls = Map.insert ident 1 s.tailCalls
  }

tcoTopLevelCall :: Qualified Ident -> Int -> TcoAnalysis -> TcoAnalysis
tcoTopLevelCall ident arity (TcoAnalysis s) = TcoAnalysis s
  { topLevelCalls = Map.insertWith append ident (Call { count: 1, arities: Set.singleton arity }) s.topLevelCalls
  , topLevelTailCalls = Map.insert ident 1 s.topLevelTailCalls
  }

tcoNoTailCalls :: TcoAnalysis -> TcoAnalysis
tcoNoTailCalls (TcoAnalysis s) = TcoAnalysis s
  { tailCalls = Map.empty
  , topLevelTailCalls = Map.empty
  }

tcoBinding :: TcoAnalysis -> TcoAnalysis
tcoBinding (TcoAnalysis s) = TcoAnalysis s { isTcoBinding = true }

isUniformTailCall :: TcoAnalysis -> Int -> Tuple (Maybe Ident) Level -> Boolean
isUniformTailCall (TcoAnalysis s) arity ref = fromMaybe false do
  numTailCalls <- Map.lookup ref s.tailCalls
  Call call <- Map.lookup ref s.calls
  case Set.toUnfoldable call.arities of
    [ n ] ->
      Just $ n > 0 && n == arity && call.count == numTailCalls
    _ ->
      Nothing

isTcoBinding :: Array (Tuple Int (Tuple (Maybe Ident) Level)) -> TcoExpr -> Maybe TcoAnalysis
isTcoBinding refs (TcoExpr _ expr) = case expr of
  Abs _ (TcoExpr analysis2 _)
    | Array.all (uncurry (isUniformTailCall analysis2)) refs ->
        Just analysis2
  _ ->
    Nothing

syntacticArity :: forall a. BackendSyntax a -> Int
syntacticArity = case _ of
  Abs args _ -> NonEmptyArray.length args
  _ -> 0

type TcoEnv =
  { candidates :: Set (Tuple (Maybe Ident) Level)
  , topLevelCandidates :: Set (Qualified Ident)
  }

emptyTcoEnv :: TcoEnv
emptyTcoEnv =
  { candidates: Set.empty
  , topLevelCandidates: Set.empty
  }

analyze :: TcoEnv -> NeutralExpr -> TcoExpr
analyze env (NeutralExpr expr) = case expr of
  Var ident ->
    TcoExpr (tcoTopLevelCall ident 0 mempty) $ Var ident
  Local ident level ->
    TcoExpr (tcoCall (Tuple ident level) 0 mempty) $ Local ident level
  Branch branches def -> do
    let branches' = map (\(Pair a b) -> Pair (overTcoAnalysis tcoNoTailCalls (analyze env a)) (analyze env b)) branches
    let def' = analyze env <$> def
    let analysis2 = foldMap (foldMap tcoAnalysisOf) branches' <> foldMap tcoAnalysisOf def'
    TcoExpr analysis2 $ Branch branches' def'
  LetRec level bindings body -> do
    let refs = flip Tuple level <<< Just <<< fst <$> bindings
    let env' = env { candidates = Set.union (Set.fromFoldable refs) env.candidates }
    let bindings' = map (analyze env') <$> bindings
    let body' = analyze env' body
    let refsWithArity = (\(Tuple ident binding) -> Tuple (syntacticArity (unTcoExpr binding)) (Tuple (Just ident) level)) <$> bindings'
    case foldMap (isTcoBinding refsWithArity <<< snd) bindings' of
      Just analysis3 -> do
        let analysis4 = analysis3 <> tcoAnalysisOf body'
        TcoExpr (tcoBinding (tcoBound refs analysis4)) $ LetRec level bindings' body'
      Nothing -> do
        let analysis3 = foldMap (foldMap tcoAnalysisOf) bindings'
        let analysis4 = analysis3 <> tcoAnalysisOf body'
        TcoExpr (tcoNoTailCalls (tcoBound refs analysis4)) $ LetRec level bindings' body'
  Let ident level binding body -> do
    let binding' = analyze env binding
    let body' = analyze env body
    let analysis3 = tcoAnalysisOf body'
    let analysis4 = tcoAnalysisOf binding' <> tcoBound [ Tuple ident level ] analysis3
    let newExpr = Let ident level binding' body'
    if isUniformTailCall analysis3 (syntacticArity (unwrap binding)) (Tuple ident level) then
      TcoExpr analysis4 newExpr
    else
      TcoExpr (tcoNoTailCalls analysis4) newExpr
  App hd@(NeutralExpr (Local ident level)) tl -> do
    let hd' = analyze env hd
    let tl' = overTcoAnalysis tcoNoTailCalls <<< analyze env <$> tl
    let analysis2 = tcoCall (Tuple ident level) (NonEmptyArray.length tl') (foldMap tcoAnalysisOf tl')
    TcoExpr analysis2 $ App hd' tl'
  App hd@(NeutralExpr (Var ident)) tl -> do
    let hd' = analyze env hd
    let tl' = overTcoAnalysis tcoNoTailCalls <<< analyze env <$> tl
    let analysis2 = tcoTopLevelCall ident (NonEmptyArray.length tl') (foldMap tcoAnalysisOf tl')
    TcoExpr analysis2 $ App hd' tl'
  App _ _ ->
    defaultAnalyze env expr
  Abs _ _ ->
    defaultAnalyze env expr
  UncurriedApp _ _ ->
    defaultAnalyze env expr
  UncurriedAbs _ _ ->
    defaultAnalyze env expr
  UncurriedEffectApp _ _ ->
    defaultAnalyze env expr
  UncurriedEffectAbs _ _ ->
    defaultAnalyze env expr
  Accessor _ _ ->
    defaultAnalyze env expr
  Update _ _ ->
    defaultAnalyze env expr
  CtorSaturated _ _ _ ->
    defaultAnalyze env expr
  CtorDef _ _ ->
    defaultAnalyze env expr
  EffectBind _ _ _ _ ->
    defaultAnalyze env expr
  EffectPure _ ->
    defaultAnalyze env expr
  Lit _ ->
    defaultAnalyze env expr
  Test _ _ ->
    defaultAnalyze env expr
  Fail _ ->
    defaultAnalyze env expr

defaultAnalyze :: TcoEnv -> BackendSyntax NeutralExpr -> TcoExpr
defaultAnalyze env expr = do
  let expr' = analyze env <$> expr
  TcoExpr (tcoNoTailCalls (foldMap tcoAnalysisOf expr')) expr'
