module PureScript.Backend.Codegen.EcmaScript where

import Prelude

import Data.Array as Array
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as NonEmptyArray
import Data.Foldable (class Foldable, fold, foldMap, foldl, foldr)
import Data.FunctorWithIndex (mapWithIndex)
import Data.List (List)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isNothing, maybe)
import Data.Monoid as Monoid
import Data.Newtype (unwrap)
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.String.Regex as Regex
import Data.String.Regex.Flags (noFlags)
import Data.String.Regex.Unsafe (unsafeRegex)
import Data.Traversable (class Traversable, Accum, mapAccumL)
import Data.TraversableWithIndex (mapAccumLWithIndex)
import Data.Tuple (Tuple(..), fst, snd, uncurry)
import Dodo as Dodo
import Dodo.Common as Dodo.Common
import PureScript.Backend.Convert (BackendBindingGroup, BackendModule)
import PureScript.Backend.Semantics (NeutralExpr(..))
import PureScript.Backend.Syntax (BackendAccessor(..), BackendGuard(..), BackendSyntax(..), Level(..), Pair(..))
import PureScript.Backend.TCO (TcoAnalysis(..), TcoExpr(..))
import PureScript.Backend.TCO as TCO
import PureScript.CoreFn (Ident(..), Literal(..), ModuleName(..), Prop(..), Qualified(..), qualifiedModuleName, unQualified)

data CodegenName = CodegenIdent Ident

type CodegenEnv =
  { currentModule :: ModuleName
  , bound :: Map Ident Int
  , names :: Map (Tuple Ident Level) Ident
  , tcoScope :: Maybe TcoScope
  }

type LocalRef = Tuple (Maybe Ident) Level

type TcoScope =
  { local :: List TcoScopeItemLocal
  , topLevel :: Maybe TcoScopeItemTopLevel
  }

type TcoScopeItem a = Tuple Ident (Set a)
type TcoScopeItemLocal = TcoScopeItem (Tuple Ident Level)
type TcoScopeItemTopLevel = TcoScopeItem (Qualified Ident)

noTco :: CodegenEnv -> CodegenEnv
noTco env
  | isNothing env.tcoScope = env
  | otherwise = env { tcoScope = Nothing }

isLocalTcoJump :: Ident -> Level -> TcoScope -> Maybe (Tuple Ident (List Ident))
isLocalTcoJump ident level { local } = go List.Nil local
  where
  go pop = case _ of
    List.Cons (Tuple tcoIdent tcoGroup) rest
      | Set.member (Tuple ident level) tcoGroup ->
          Just (Tuple tcoIdent pop)
      | otherwise ->
          go (List.Cons tcoIdent pop) rest
    _ ->
      Nothing

isTopLevelTcoJump :: Qualified Ident -> TcoScope -> Maybe (Tuple Ident (List Ident))
isTopLevelTcoJump ident { local, topLevel } = case topLevel of
  Just (Tuple tcoIdent tcoGroup)
    | Set.member ident tcoGroup ->
        Just (Tuple tcoIdent (fst <$> local))
  _ ->
    Nothing

pushLocalTcoScope :: Tuple Ident (Set (Tuple Ident Level)) -> CodegenEnv -> CodegenEnv
pushLocalTcoScope scopeItem env = env
  { tcoScope = Just { local: List.singleton scopeItem, topLevel: Nothing }
  }

-- TODO: handle nested TCO loops
-- { tcoScope = case env.tcoScope of
--     Nothing ->
--       Just { local: List.singleton scopeItem, topLevel: Nothing }
--     Just scope ->
--       Just scope { local = List.Cons scopeItem scope.local }
-- }

type TcoBinding =
  { arguments :: NonEmptyArray (Tuple (Maybe Ident) Level)
  , body :: TcoExpr
  , name :: Ident
  }

getLocalTcoBinding :: Array (Tuple Ident TcoExpr) -> Maybe TcoBinding
getLocalTcoBinding bindings = case bindings of
  [ Tuple ident (TcoExpr _ (Abs arguments body)) ] ->
    Just { arguments, body, name: ident }
  _ ->
    Nothing

freshName :: Maybe Ident -> Level -> CodegenEnv -> Tuple Ident CodegenEnv
freshName ident lvl env = case ident of
  Nothing ->
    Tuple (Ident ("_" <> show (unwrap lvl))) env
  Just id ->
    case Map.lookup id env.bound of
      Nothing ->
        Tuple id $ env
          { bound = Map.insert id 1 env.bound
          , names = Map.insert (Tuple id lvl) id env.names
          }
      Just n -> do
        let fresh = Ident (unwrap id <> "_" <> show n)
        Tuple fresh $ env
          { bound = Map.insert id (n + 1) env.bound
          , names = Map.insert (Tuple id lvl) fresh env.names
          }

freshNames :: forall f. Traversable f => CodegenEnv -> f LocalRef -> Accum CodegenEnv (f Ident)
freshNames = mapAccumL \env' (Tuple ident level) -> do
  let Tuple newIdent env'' = freshName ident level env'
  { accum: env'', value: newIdent }

freshBindingGroup :: forall f a. Traversable f => Level -> CodegenEnv -> f (Tuple Ident a) -> Accum CodegenEnv (f (Tuple Ident a))
freshBindingGroup level = mapAccumL \env' (Tuple ident binding) -> do
  let Tuple newIdent env'' = freshName (Just ident) level env'
  { accum: env''
  , value: Tuple newIdent binding
  }

rename :: Maybe Ident -> Level -> CodegenEnv -> Ident
rename ident lvl env =
  case ident >>= \id -> Map.lookup (Tuple id lvl) env.names of
    Nothing ->
      esLocalIdent ident lvl
    Just id ->
      id

esCodegenModule :: forall a. BackendModule -> Dodo.Doc a
esCodegenModule mod@{ name: ModuleName this } = do
  let
    foreignModuleName =
      ModuleName (this <> "$foreign")

    foreignBindings = map
      (\ident -> Tuple ident $ NeutralExpr $ Var $ Qualified (Just foreignModuleName) ident)
      mod.foreign

    moduleBindings = map
      (\r -> r { bindings = map TCO.analyze <$> r.bindings })
      (Array.cons { recursive: false, bindings: foreignBindings } mod.bindings)

    codegenEnv =
      { currentModule: mod.name
      , bound: Map.empty
      , names: Map.empty
      , tcoScope: Nothing
      }

    exportsByPath = mod.exports
      # Array.groupAllBy (comparing (qualifiedModuleName <<< snd))
      # map (\as -> Tuple (esModulePath <$> qualifiedModuleName (snd (NonEmptyArray.head as))) (map unQualified <$> as))

  esBlockStatements $ fold
    [ (\mn -> Statement (esImport mn (esModulePath mn))) <$> mod.imports
    , Monoid.guard (not (Array.null foreignBindings)) [ Statement (esImport foreignModuleName (esForeignModulePath mod.name)) ]
    , map Statement $ esCodegenBindingGroup codegenEnv =<< moduleBindings
    , map (Statement <<< uncurry (maybe esExports esExportsFrom)) exportsByPath
    ]

esCodegenExpr :: forall a. CodegenEnv -> TcoExpr -> Dodo.Doc a
esCodegenExpr env tcoExpr@(TcoExpr _ expr) = case expr of
  Var (Qualified (Just (ModuleName "Prim")) (Ident "undefined")) ->
    esUndefined
  Var (Qualified (Just mn) ident) | mn == env.currentModule ->
    esCodegenIdent ident
  Var var ->
    esCodegenQualified esCodegenIdent var
  Local ident lvl ->
    esCodegenIdent (rename ident lvl env)
  Lit lit ->
    esCodegenLit (noTco env) lit
  App a bs ->
    esCurriedApp (esCodegenExpr (noTco env) a) (esCodegenExpr (noTco env) <$> bs)
  Abs idents body
    | [ Tuple (Just (Ident "$__unused")) _ ] <- NonEmptyArray.toArray idents ->
        esFn [] (esCodegenBlockStatements pureMode (noTco env) body)
    | otherwise -> do
        let result = freshNames env idents
        esCurriedFn result.value (esCodegenBlockStatements pureMode (noTco result.accum) body)
  UncurriedAbs idents body -> do
    let result = freshNames env idents
    esFn result.value (esCodegenBlockStatements pureMode (noTco result.accum) body)
  UncurriedApp a bs ->
    esApp (esCodegenExpr (noTco env) a) (esCodegenExpr (noTco env) <$> bs)
  UncurriedEffectAbs idents body -> do
    let result = freshNames env idents
    esFn result.value (esCodegenBlockStatements effectMode (noTco result.accum) body)
  UncurriedEffectApp _ _ ->
    esCodegenEffectBlock env tcoExpr
  Accessor a prop ->
    esCodegenAccessor (esCodegenExpr (noTco env) a) prop
  Update a props ->
    esUpdate (esCodegenExpr (noTco env) a) (map (esCodegenExpr (noTco env)) <$> props)
  CtorDef (Ident tag) [] ->
    esCtor tag []
  CtorDef (Ident tag) fields ->
    esCurriedFn fields [ Return (esCtor tag (esCodegenIdent <$> fields)) ]
  CtorSaturated _ (Ident tag) fields ->
    esCtor tag (esCodegenExpr (noTco env) <<< snd <$> fields)
  Test a b -> do
    let lhs = esCodegenExpr (noTco env) a
    case a, b of
      TcoExpr _ (Local _ _), GuardBoolean true ->
        lhs
      _, _ ->
        esCodegenTest lhs b
  Fail str ->
    esError str
  Branch _ _ ->
    esCodegenBlock env tcoExpr
  LetRec _ _ _ ->
    esCodegenBlock env tcoExpr
  Let _ _ _ _ ->
    esCodegenBlock env tcoExpr
  EffectBind _ _ _ _ ->
    esCodegenEffectBlock (noTco env) tcoExpr
  EffectPure _ ->
    esCodegenEffectBlock (noTco env) tcoExpr

esCodegenLit :: forall a. CodegenEnv -> Literal TcoExpr -> Dodo.Doc a
esCodegenLit env = case _ of
  LitInt n ->
    esInt n
  LitNumber n ->
    esNumber n
  LitString str ->
    esString str
  LitChar ch ->
    esChar ch
  LitBoolean bool ->
    Dodo.text (show bool)
  LitArray as ->
    esArray (esCodegenExpr env <$> as)
  LitRecord props ->
    esRecord (map (esCodegenExpr env) <$> props)

esCodegenBlock :: forall a. CodegenEnv -> TcoExpr -> Dodo.Doc a
esCodegenBlock env a = esBlock (esCodegenBlockStatements pureMode env a)

esCodegenEffectBlock :: forall a. CodegenEnv -> TcoExpr -> Dodo.Doc a
esCodegenEffectBlock env a = esEffectBlock (esCodegenBlockStatements effectMode env a)

data EsStatement a
  = Statement a
  | Control a
  | Return a
  | ReturnObject a
  | ReturnUndefined

type BlockMode =
  { effect :: Boolean
  , tco :: Boolean
  }

pureMode :: BlockMode
pureMode = { tco: false, effect: false }

effectMode :: BlockMode
effectMode = { tco: false, effect: true }

esCodegenBlockStatements :: forall a. BlockMode -> CodegenEnv -> TcoExpr -> Array (EsStatement (Dodo.Doc a))
esCodegenBlockStatements mode = (\env expr -> go env [] expr)
  where
  go env acc tcoExpr@(TcoExpr (TcoAnalysis analysis) expr) = case expr of
    LetRec lvl bindings body
      | analysis.isTcoBinding
      , Just tco <- getLocalTcoBinding bindings -> do
          let Tuple tcoIdent env' = freshName (Just tco.name) lvl env
          let env'' = pushLocalTcoScope (Tuple tcoIdent (Set.singleton (Tuple tcoIdent lvl))) env'
          let line = Statement $ esBinding tcoIdent $ esCodegenTcoBinding env'' tcoIdent tco
          go env' (Array.snoc acc line) body
      | otherwise -> do
          let result = freshBindingGroup lvl env bindings
          let lines = Statement <$> esCodegenBindingGroup result.accum { recursive: true, bindings: result.value }
          go result.accum (acc <> lines) body
    Let ident lvl binding body -> do
      let Tuple newIdent env' = freshName ident lvl env
      let lines = Statement <$> esCodegenBindingGroup env { recursive: false, bindings: [ Tuple newIdent binding ] }
      go env' (acc <> lines) body
    Branch bs def ->
      Array.snoc acc (Control (esCodegenBlockBranches mode env bs def))
    Fail _ ->
      Array.snoc acc (Statement (esCodegenExpr env tcoExpr))
    UncurriedEffectApp a bs | mode.effect -> do
      let line = esApp (esCodegenExpr env a) (esCodegenExpr env <$> bs)
      Array.snoc acc (Return line)
    EffectBind ident lvl (TcoExpr _ (UncurriedEffectApp a bs)) body | mode.effect -> do
      let Tuple newIdent env' = freshName ident lvl env
      let line = Statement $ esBinding newIdent (esApp (esCodegenExpr env a) (esCodegenExpr env <$> bs))
      go env' (Array.snoc acc line) body
    EffectBind (Just (Ident "$__unused")) _ eff body | mode.effect -> do
      let line = Statement $ esApp (esCodegenExpr env eff) []
      go env (Array.snoc acc line) body
    EffectBind ident lvl eff body | mode.effect -> do
      let Tuple newIdent env' = freshName ident lvl env
      let line = Statement $ esBinding newIdent (esApp (esCodegenExpr env eff) [])
      go env' (Array.snoc acc line) body
    EffectPure expr' | mode.effect ->
      case expr' of
        TcoExpr _ (Lit (LitRecord _)) ->
          Array.snoc acc (ReturnObject (esCodegenExpr env expr'))
        _ ->
          Array.snoc acc (Return (esCodegenExpr env expr'))
    App (TcoExpr _ (Local (Just ident) lvl)) bs | Just tco <- isLocalTcoJump ident lvl =<< env.tcoScope ->
      acc <>
        [ Statement $ esCodegenTcoJump tco (esCodegenExpr (noTco env) <$> bs)
        , Statement $ esContinue
        -- TODO: handle nested tco loops
        -- , if mode.tco && List.null (snd tco) then
        --     Statement $ esContinue
        --   else
        --     ReturnUndefined
        ]
    Lit (LitRecord _) ->
      Array.snoc acc (ReturnObject (esCodegenExpr env tcoExpr))
    _ ->
      Array.snoc acc (Return (esCodegenExpr env tcoExpr))

esCodegenBlockBranches :: forall a. BlockMode -> CodegenEnv -> Array (Pair TcoExpr) -> Maybe TcoExpr -> Dodo.Doc a
esCodegenBlockBranches mode env bs def = esBranches (go <$> bs) (esCodegenBlockStatements mode env <$> def)
  where
  go :: Pair TcoExpr -> Tuple (Dodo.Doc a) (Array (EsStatement (Dodo.Doc a)))
  go (Pair a b@(TcoExpr _ b')) = case b' of
    Branch next nextDef ->
      Tuple (esCodegenExpr (noTco env) a) [ Control (esCodegenBlockBranches mode env next nextDef) ]
    _ ->
      Tuple (esCodegenExpr (noTco env) a) (esCodegenBlockStatements mode env b)

esCodegenBindingGroup :: forall a. CodegenEnv -> BackendBindingGroup Ident TcoExpr -> Array (Dodo.Doc a)
esCodegenBindingGroup env { recursive, bindings }
  | recursive = do
      let fwdRefs = esFwdRef <<< fst <$> bindings
      fwdRefs <> map (\(Tuple ident b) -> esAssign ident (esCodegenExpr env b)) bindings
  | otherwise =
      map (\(Tuple ident b) -> esBinding ident (esCodegenExpr env b)) bindings

esCodegenTcoBinding :: forall a. CodegenEnv -> Ident -> TcoBinding -> Dodo.Doc a
esCodegenTcoBinding env tcoIdent tco = do
  let
    result = mapAccumLWithIndex
      ( \ix env' (Tuple ident level) -> do
          let Tuple ident' env'' = freshName ident level env'
          { accum: env''
          , value: Tuple (esTcoArgIdent tcoIdent ix) ident'
          }
      )
      env
      tco.arguments
  esTcoFn1 (esTcoLoopIdent tcoIdent) (fst <$> result.value) $ Dodo.lines
    [ Dodo.lines $ map
        ( \(Tuple arg var) ->
            esLetBinding var (esCodegenIdent arg) <> Dodo.text ";"
        )
        result.value
    , esBlockStatements $ esCodegenBlockStatements { tco: true, effect: false } result.accum tco.body
    ]

esCodegenTcoJump :: forall a. Tuple Ident (List Ident) -> NonEmptyArray (Dodo.Doc a) -> Dodo.Doc a
esCodegenTcoJump (Tuple tcoIdent stk) args =
  Dodo.foldWithSeparator (Dodo.text ";" <> Dodo.break) $ Array.snoc
    (flip esAssign (Dodo.text "false") <<< esTcoLoopIdent <$> List.toUnfoldable stk)
    (esTcoApp tcoIdent args)

esCodegenTest :: forall a. Dodo.Doc a -> BackendGuard -> Dodo.Doc a
esCodegenTest lhs = case _ of
  GuardNumber n ->
    Dodo.words [ lhs, Dodo.text "==", esNumber n ]
  GuardInt n ->
    Dodo.words [ lhs, Dodo.text "==", esInt n ]
  GuardString str ->
    Dodo.words [ lhs, Dodo.text "==", esString str ]
  GuardBoolean bool ->
    Dodo.words [ lhs, Dodo.text "==", esBoolean bool ]
  GuardChar ch ->
    Dodo.words [ lhs, Dodo.text "==", esChar ch ]
  GuardTag (Qualified _ (Ident tag)) ->
    Dodo.words [ esIndex lhs 0, Dodo.text "==", esString tag ]
  GuardArrayLength len ->
    Dodo.words [ lhs <> Dodo.text ".n", Dodo.text "==", esInt len ]

esCodegenAccessor :: forall a. Dodo.Doc a -> BackendAccessor -> Dodo.Doc a
esCodegenAccessor lhs = case _ of
  GetProp p ->
    esAccessor lhs p
  GetIndex n ->
    esIndex lhs n
  GetOffset n ->
    esOffset lhs n

esLocalIdent :: Maybe Ident -> Level -> Ident
esLocalIdent mb (Level lvl) = case mb of
  Just (Ident a) ->
    Ident (a <> "_" <> show lvl)
  Nothing ->
    Ident ("_" <> show lvl)

esCodegenIdent :: forall a. Ident -> Dodo.Doc a
esCodegenIdent (Ident a) = Dodo.text (esEscapeIdent a)

esCodegenQualified :: forall a b. (a -> Dodo.Doc b) -> Qualified a -> Dodo.Doc b
esCodegenQualified codegenInner (Qualified qual inner) = case qual of
  Nothing -> codegenInner inner
  Just mn -> esCodegenModuleName mn <> Dodo.text "." <> codegenInner inner

esCodegenModuleName :: forall a. ModuleName -> Dodo.Doc a
esCodegenModuleName (ModuleName mn) = Dodo.text (esEscapeIdent mn)

esEscapeIdent :: String -> String
esEscapeIdent = escapeReserved
  where
  escapeReserved str
    | Set.member str reservedNames =
        "$$" <> str
    | otherwise =
        escapeSpecial str

  escapeSpecial =
    String.replaceAll (String.Pattern "'") (String.Replacement "$p")
      >>> String.replaceAll (String.Pattern ".") (String.Replacement "$d")

  reservedNames = Set.fromFoldable
    [ "AggregateError"
    , "Array"
    , "ArrayBuffer"
    , "AsyncFunction"
    , "AsyncGenerator"
    , "AsyncGeneratorFunction"
    , "Atomics"
    , "BigInt"
    , "BigInt64Array"
    , "BigUint64Array"
    , "Boolean"
    , "Boolean"
    , "DataView"
    , "Date"
    , "Error"
    , "EvalError"
    , "Float32Array"
    , "Float64Array"
    , "Function"
    , "Generator"
    , "GeneratorFunction"
    , "Infinity"
    , "Int16Array"
    , "Int32Array"
    , "Int8Array"
    , "Intl"
    , "JSON"
    , "Map"
    , "Math"
    , "NaN"
    , "Number"
    , "Object"
    , "Promise"
    , "Proxy"
    , "RangeError"
    , "ReferenceError"
    , "Reflect"
    , "RegExp"
    , "Set"
    , "SharedArrayBuffer"
    , "String"
    , "Symbol"
    , "SyntaxError"
    , "TypeError"
    , "URIError"
    , "Uint16Array"
    , "Uint32Array"
    , "Uint8Array"
    , "Uint8ClampedArray"
    , "WeakMap"
    , "WeakSet"
    , "WebAssembly"
    , "abstract"
    , "arguments"
    , "await"
    , "boolean"
    , "break"
    , "byte"
    , "case"
    , "catch"
    , "char"
    , "class"
    , "const"
    , "continue"
    , "debugger"
    , "default"
    , "delete"
    , "do"
    , "double"
    , "else"
    , "enum"
    , "eval"
    , "export"
    , "extends"
    , "false"
    , "final"
    , "finally"
    , "float"
    , "for"
    , "function"
    , "get"
    , "globalThis"
    , "goto"
    , "if"
    , "implements"
    , "import"
    , "in"
    , "instanceof"
    , "int"
    , "interface"
    , "let"
    , "long"
    , "native"
    , "new"
    , "null"
    , "package"
    , "private"
    , "protected"
    , "public"
    , "return"
    , "set"
    , "short"
    , "static"
    , "super"
    , "switch"
    , "synchronized"
    , "this"
    , "throw"
    , "throws"
    , "transient"
    , "true"
    , "try"
    , "typeof"
    , "undefined"
    , "var"
    , "void"
    , "volatile"
    , "while"
    , "with"
    , "yield"
    ]

esFwdRef :: forall a. Ident -> Dodo.Doc a
esFwdRef ident = Dodo.text "let" <> Dodo.space <> esCodegenIdent ident

esLetBinding :: forall a. Ident -> Dodo.Doc a -> Dodo.Doc a
esLetBinding ident b = Dodo.words
  [ Dodo.text "let"
  , esCodegenIdent ident
  , Dodo.text "="
  , b
  ]

esBinding :: forall a. Ident -> Dodo.Doc a -> Dodo.Doc a
esBinding ident b = Dodo.words
  [ Dodo.text "const"
  , esCodegenIdent ident
  , Dodo.text "="
  , b
  ]

esAssign :: forall a. Ident -> Dodo.Doc a -> Dodo.Doc a
esAssign ident b = Dodo.words
  [ esCodegenIdent ident
  , Dodo.text "="
  , b
  ]

esAssignProp :: forall a. Ident -> Prop (Dodo.Doc a) -> Dodo.Doc a
esAssignProp ident (Prop prop val) = fold
  [ esCodegenIdent ident
  , Dodo.Common.jsSquares (Dodo.text (show prop))
  , Dodo.space
  , Dodo.text "="
  , Dodo.space
  , val
  ]

esAccessor :: forall a. Dodo.Doc a -> String -> Dodo.Doc a
esAccessor expr prop = case esEscapeProp prop of
  Nothing ->
    expr <> Dodo.text "." <> Dodo.text prop
  Just escaped ->
    expr <> Dodo.Common.jsSquares (Dodo.text escaped)

esIndex :: forall a. Dodo.Doc a -> Int -> Dodo.Doc a
esIndex expr ix = expr <> Dodo.text "[" <> Dodo.text (show ix) <> Dodo.text "]"

esOffset :: forall a. Dodo.Doc a -> Int -> Dodo.Doc a
esOffset expr ix = expr <> Dodo.text "[" <> Dodo.text (show (ix + 1)) <> Dodo.text "]"

esUpdate :: forall a. Dodo.Doc a -> Array (Prop (Dodo.Doc a)) -> Dodo.Doc a
esUpdate rec props = Dodo.Common.jsCurlies $ Dodo.foldWithSeparator Dodo.Common.trailingComma $ Array.cons (Dodo.text "..." <> rec) (esProp <$> props)

esBlock :: forall a. Array (EsStatement (Dodo.Doc a)) -> Dodo.Doc a
esBlock stmts = esFn mempty stmts <> Dodo.text "()"

esEffectBlock :: forall a. Array (EsStatement (Dodo.Doc a)) -> Dodo.Doc a
esEffectBlock stmts = esFn mempty stmts

esBlockStatements :: forall a. Array (EsStatement (Dodo.Doc a)) -> Dodo.Doc a
esBlockStatements = Dodo.lines <<< map go
  where
  go = case _ of
    Statement a -> a <> Dodo.text ";"
    Control a -> a
    Return a -> esReturn a <> Dodo.text ";"
    ReturnObject a -> esReturn a <> Dodo.text ";"
    ReturnUndefined -> esReturn mempty <> Dodo.text ";"

esFn :: forall a. Array Ident -> Array (EsStatement (Dodo.Doc a)) -> Dodo.Doc a
esFn args stmts = Dodo.words
  [ if Array.length args == 1 then
      foldMap esCodegenIdent args
    else
      Dodo.Common.jsParens (Dodo.foldWithSeparator Dodo.Common.trailingComma (esCodegenIdent <$> args))
  , Dodo.text "=>"
  , esFnBody stmts
  ]

esReturn :: forall a. Dodo.Doc a -> Dodo.Doc a
esReturn doc = Dodo.words
  [ Dodo.text "return"
  , doc
  ]

esCurriedFn :: forall f a. Foldable f => f Ident -> Array (EsStatement (Dodo.Doc a)) -> Dodo.Doc a
esCurriedFn args stmts = foldr go (esFnBody stmts) args
  where
  go arg body = Dodo.words
    [ esCodegenIdent arg
    , Dodo.text "=>"
    , body
    ]

esFnBody :: forall a. Array (EsStatement (Dodo.Doc a)) -> Dodo.Doc a
esFnBody = case _ of
  [] -> Dodo.Common.jsCurlies mempty
  [ Return a ] -> a
  [ ReturnObject a ] -> Dodo.Common.jsParens a
  stmts -> Dodo.Common.jsCurlies (esBlockStatements stmts)

esArray :: forall a. Array (Dodo.Doc a) -> Dodo.Doc a
esArray = Dodo.Common.jsSquares <<< Dodo.foldWithSeparator Dodo.Common.trailingComma

esRecord :: forall a. Array (Prop (Dodo.Doc a)) -> Dodo.Doc a
esRecord = Dodo.Common.jsCurlies <<< Dodo.foldWithSeparator Dodo.Common.trailingComma <<< map esProp

esProp :: forall a. Prop (Dodo.Doc a) -> Dodo.Doc a
esProp (Prop prop val) = fold
  [ Dodo.text (fromMaybe prop $ esEscapeProp prop)
  , Dodo.text ":"
  , Dodo.space
  , val
  ]

esEscapeProp :: String -> Maybe String
esEscapeProp = \prop ->
  if Regex.test safeRegex prop then
    Nothing
  else
    Just $ show prop
  where
  safeRegex = unsafeRegex """^[a-zA-Z_$][a-zA-Z0-9_$]*$""" noFlags

esCtor :: forall a. String -> Array (Dodo.Doc a) -> Dodo.Doc a
esCtor tag vals = Dodo.Common.jsSquares $
  Dodo.foldWithSeparator Dodo.Common.trailingComma (Array.cons (esString tag) vals)

esString :: forall a. String -> Dodo.Doc a
esString = Dodo.text <<< show

esNumber :: forall a. Number -> Dodo.Doc a
esNumber = Dodo.text <<< show

esInt :: forall a. Int -> Dodo.Doc a
esInt = Dodo.text <<< show

esChar :: forall a. Char -> Dodo.Doc a
esChar = Dodo.text <<< show

esBoolean :: forall a. Boolean -> Dodo.Doc a
esBoolean = Dodo.text <<< show

esApp :: forall f a. Foldable f => Dodo.Doc a -> f (Dodo.Doc a) -> Dodo.Doc a
esApp a bs = a <> Dodo.Common.jsParens (Dodo.foldWithSeparator Dodo.Common.trailingComma bs)

esCurriedApp :: forall a. Dodo.Doc a -> NonEmptyArray (Dodo.Doc a) -> Dodo.Doc a
esCurriedApp = foldl (\a b -> a <> Dodo.Common.jsParens b)

esIfElse :: forall f a. Foldable f => f (Tuple (Dodo.Doc a) (Dodo.Doc a)) -> Dodo.Doc a -> Dodo.Doc a
esIfElse conds default = Dodo.lines
  [ condChain.doc
  , Monoid.guard (not (Dodo.isEmpty default)) $ fold
      [ Dodo.text "else"
      , Dodo.space
      , Dodo.Common.jsCurlies default
      ]
  ]
  where
  condChain = foldl go { elseif: false, doc: mempty } conds
  go { elseif, doc } (Tuple cond body) =
    { elseif: true
    , doc: fold
        [ doc
        , if elseif then Dodo.space <> Dodo.text "else if" else Dodo.text "if"
        , Dodo.space
        , Dodo.Common.jsParens cond
        , Dodo.space
        , Dodo.Common.jsCurlies body
        ]
    }

esBranches :: forall a. Array (Tuple (Dodo.Doc a) (Array (EsStatement (Dodo.Doc a)))) -> Maybe (Array (EsStatement (Dodo.Doc a))) -> Dodo.Doc a
esBranches branches def =
  Dodo.lines
    [ Dodo.lines $ map
        ( \(Tuple doc stmts) -> Dodo.flexGroup $ fold
            [ Dodo.text "if"
            , Dodo.space
            , Dodo.Common.jsParens doc
            , Dodo.space
            , Dodo.text "{"
            , Dodo.spaceBreak
            , Dodo.indent (esBlockStatements stmts)
            , Dodo.spaceBreak
            , Dodo.text "}"
            ]
        )
        branches
    , foldMap esBlockStatements def
    ]

esImport :: forall a. ModuleName -> String -> Dodo.Doc a
esImport mn path = Dodo.words
  [ Dodo.text "import"
  , Dodo.text "*"
  , Dodo.text "as"
  , esCodegenModuleName mn
  , Dodo.text "from"
  , Dodo.text (show path)
  ]

esExports :: forall a. NonEmptyArray (Tuple Ident Ident) -> Dodo.Doc a
esExports exports = Dodo.words
  [ Dodo.text "export"
  , Dodo.Common.jsCurlies $ Dodo.foldWithSeparator Dodo.Common.trailingComma $ map
      ( \(Tuple id1 id2) ->
          if id1 == id2 then
            esCodegenIdent id1
          else
            Dodo.words
              [ esCodegenIdent id2
              , Dodo.text "as"
              , esCodegenIdent id1
              ]
      )
      exports
  ]

esExportsFrom :: forall a. String -> NonEmptyArray (Tuple Ident Ident) -> Dodo.Doc a
esExportsFrom path exports = Dodo.words
  [ esExports exports
  , Dodo.text "from"
  , Dodo.text (show path)
  ]

esModulePath :: ModuleName -> String
esModulePath (ModuleName mn) = "./" <> mn <> ".js"

esForeignModulePath :: ModuleName -> String
esForeignModulePath (ModuleName mn) = "./" <> mn <> ".foreign.js"

esUndefined :: forall a. Dodo.Doc a
esUndefined = mempty

esError :: forall a. String -> Dodo.Doc a
esError str = Dodo.words
  [ Dodo.text "throw"
  , Dodo.text "new"
  , esApp (Dodo.text "Error") [ esString str ]
  ]

esTcoLoopIdent :: Ident -> Ident
esTcoLoopIdent (Ident tcoIdent) = Ident (tcoIdent <> "$loop")

esTcoArgIdent :: Ident -> Int -> Ident
esTcoArgIdent (Ident tcoIdent) ix = Ident (tcoIdent <> "$" <> show ix)

esTcoFn1 :: forall a. Ident -> NonEmptyArray Ident -> Dodo.Doc a -> Dodo.Doc a
esTcoFn1 _ args body = esCurriedFn args
  [ Statement $ Dodo.words
      [ Dodo.text "while"
      , Dodo.Common.jsParens (Dodo.text "true")
      , Dodo.Common.jsCurlies body
      ]
  ]

-- TODO: handle nested tco loops
-- [ Statement $ esLetBinding loopIdent (Dodo.text "true")
-- , Statement $ Dodo.words
--     [ Dodo.text "while"
--     , Dodo.Common.jsParens (esCodegenIdent loopIdent)
--     , Dodo.Common.jsCurlies body
--     ]
-- ]

esTcoApp :: forall a. Ident -> NonEmptyArray (Dodo.Doc a) -> Dodo.Doc a
esTcoApp tcoIdent args =
  Dodo.foldWithSeparator (Dodo.text ";" <> Dodo.break) $ mapWithIndex
    ( \ix arg ->
        esAssign (esTcoArgIdent tcoIdent ix) arg
    )
    args

esContinue :: forall a. Dodo.Doc a
esContinue = Dodo.text "continue"