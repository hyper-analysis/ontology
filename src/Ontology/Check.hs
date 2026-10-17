module Ontology.Check
  ( checkOntology
  , ontologySummary
  ) where

import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (find, nub)
import Ontology.Syntax

data BuildState = BuildState
  { nextNode :: NodeId
  , builtNodes :: M.Map NodeId Node
  , builtNames :: M.Map Name NodeId
  , resolving :: S.Set Name
  }

type Build = StateT BuildState (Either String)

emptyState :: BuildState
emptyState = BuildState 0 M.empty M.empty S.empty

raise :: String -> Build a
raise = lift . Left

fresh :: Node -> Build NodeId
fresh n = do
  i <- gets nextNode
  modify' $ \s -> s { nextNode = i + 1, builtNodes = M.insert i n (builtNodes s) }
  pure i

lookupDecl :: Module -> Name -> Build TypeExpr
lookupDecl (Module ds) name =
  maybe (raise ("unknown type " ++ name)) pure (M.lookup name ds)

resolveName :: Module -> Name -> Build NodeId
resolveName m name = do
  old <- gets (M.lookup name . builtNames)
  case old of
    Just i -> pure i
    Nothing -> do
      active <- gets resolving
      when (S.member name active) $
        raise ("recursive value definition " ++ name ++ "; recursion must pass through Ref")
      expr <- lookupDecl m name
      modify' $ \s -> s { resolving = S.insert name (resolving s) }
      normalized <- normalizeTop m S.empty expr
      i <- buildExpr m normalized
      modify' $ \s -> s
        { resolving = S.delete name (resolving s)
        , builtNames = M.insert name i (builtNames s)
        }
      pure i

normalizeTop :: Module -> S.Set Name -> TypeExpr -> Build TypeExpr
normalizeTop m seen expr = case expr of
  Intersection xs -> Object <$> mergeObjects m seen xs
  _ -> pure expr

mergeObjects :: Module -> S.Set Name -> [TypeExpr] -> Build [FieldExpr]
mergeObjects m seen xs = foldM merge [] =<< mapM (fieldsOf seen) xs
  where
    fieldsOf _ (Object fs) = pure fs
    fieldsOf active (Intersection ys) = mergeObjects m active ys
    fieldsOf active (Named n)
      | S.member n active = raise ("recursive object composition through " ++ n)
      | otherwise = do
          next <- lookupDecl m n
          normalized <- normalizeTop m (S.insert n active) next
          fieldsOf (S.insert n active) normalized
    fieldsOf _ other = raise ("intersection is only object-field composition, found " ++ short other)

    merge acc incoming = foldM add acc incoming
    add acc f =
      case find ((== fieldExprName f) . fieldExprName) acc of
        Nothing -> pure (acc ++ [f])
        Just old
          | fieldExprType old == fieldExprType f ->
              let combined = old
                    { fieldExprOptional = fieldExprOptional old && fieldExprOptional f
                    , fieldExprKey = fieldExprKey old || fieldExprKey f
                    }
              in pure (map (\x -> if fieldExprName x == fieldExprName f then combined else x) acc)
          | otherwise ->
              raise ("conflicting definitions of field " ++ fieldExprName f ++ " in object intersection")

short :: TypeExpr -> String
short e = case e of
  Primitive p -> show p
  Literal l -> show l
  Named n -> n
  Object _ -> "object"
  Reference n -> "Ref<" ++ n ++ ">"
  Collection _ -> "collection"
  Unique _ _ -> "unique"
  Function _ _ -> "function"
  Alternative tag _ -> "alternative " ++ tag
  Union _ -> "union"
  Intersection _ -> "intersection"

buildExpr :: Module -> TypeExpr -> Build NodeId
buildExpr m expr = case expr of
  Primitive p -> fresh (Scalar p)
  Literal l -> fresh (ScalarLiteral l)
  Named n -> resolveName m n
  Reference n -> do
    _ <- lookupDecl m n
    fresh (Ref n)
  Object fs -> Record <$> mapM (buildField m) fs >>= fresh
  Collection x -> do
    child <- buildExpr m =<< normalizeTop m S.empty x
    childNode <- getNode child
    case childNode of
      FunctionNode _ _ -> raise "collection of functions/maps is not ontological; add a named dimension instead"
      _ -> fresh (Distinct [] child)
  Unique selectors x -> case x of
    Collection inner -> do
      child <- buildExpr m =<< normalizeTop m S.empty inner
      when (not (null selectors)) $
        forM_ selectors $ \name -> do
          ok <- hasRequiredField child name
          unless ok $ raise ("distinct selector " ++ name ++ " must be a required field of every alternative")
      fresh (Distinct selectors child)
    _ -> raise "unique outside a field must qualify a collection"
  Function params result -> do
    when (null params) (raise "function/map requires at least one named parameter")
    let names = map parameterExprName params
    when (length names /= length (nub names)) (raise "function/map parameter names must be unique")
    ps <- forM params $ \p -> do
      ty <- buildExpr m =<< normalizeTop m S.empty (parameterExprType p)
      ok <- keyLike ty
      unless ok $ raise ("map parameter " ++ parameterExprName p ++ " is not a scalar/reference/value key")
      pure (Parameter (parameterExprName p) ty)
    out <- buildExpr m =<< normalizeTop m S.empty result
    outNode <- getNode out
    case outNode of
      Many _ -> raise "a function/map cannot directly return a collection; model the many-valued relation explicitly"
      Distinct _ _ -> raise "a function/map cannot directly return a collection; model the many-valued relation explicitly"
      FunctionNode _ _ -> raise "nested maps must be written as one function with multiple named parameters"
      _ -> fresh (FunctionNode ps out)
  Alternative tag branches -> do
    when (null branches) (raise ("alternative " ++ tag ++ " has no branches"))
    let labels = map branchExprName branches
    when (length labels /= length (nub labels)) (raise ("alternative " ++ tag ++ " has duplicate branch labels"))
    bs <- forM branches $ \b -> case branchExprType b of
      Named n -> Branch (branchExprName b) <$> resolveName m n
      _ -> raise ("alternative branch " ++ branchExprName b ++ " must reference a named type")
    fresh (AlternativeNode tag bs)
  Union xs -> do
    values <- fmap concat (mapM (literalSet m S.empty) xs)
    when (null values) (raise "empty literal union")
    fresh (ScalarEnum (nub values))
  Intersection _ -> normalizeTop m S.empty expr >>= buildExpr m

buildField :: Module -> FieldExpr -> Build Field
buildField m f = do
  let (isUnique, ty) = case fieldExprType f of
        Unique [] inner@(Collection _) -> (False, Unique [] inner)
        Unique selectors inner@(Collection _) -> (False, Unique selectors inner)
        Unique [] inner -> (True, inner)
        Unique _ _ -> (False, fieldExprType f)
        other -> (False, other)
  when (case fieldExprType f of Unique selectors inner -> not (null selectors) && not (isCollection inner); _ -> False) $
    raise ("field " ++ fieldExprName f ++ ": unique selectors only apply to collections")
  nodeId <- buildExpr m =<< normalizeTop m S.empty ty
  when (fieldExprKey f && fieldExprOptional f) $
    raise ("key field " ++ fieldExprName f ++ " cannot be optional")
  pure (Field (fieldExprName f) (fieldExprOptional f) isUnique (fieldExprKey f) nodeId)
  where
    isCollection (Collection _) = True
    isCollection _ = False

literalSet :: Module -> S.Set Name -> TypeExpr -> Build [Literal]
literalSet m seen expr = case expr of
  Literal l -> pure [l]
  Union xs -> concat <$> mapM (literalSet m seen) xs
  Named n
    | S.member n seen -> raise ("recursive scalar alias " ++ n)
    | otherwise -> lookupDecl m n >>= literalSet m (S.insert n seen)
  _ -> raise "raw unions are only scalar literal enumerations; entity alternatives must use alternative <tag> {...}"

getNode :: NodeId -> Build Node
getNode i = gets (M.lookup i . builtNodes) >>= maybe (raise ("internal missing node #" ++ show i)) pure

keyLike :: NodeId -> Build Bool
keyLike i = getNode i >>= \n -> case n of
  Scalar _ -> pure True
  ScalarLiteral _ -> pure True
  ScalarEnum _ -> pure True
  Ref _ -> pure True
  Record fs -> and <$> mapM (\f -> if fieldOptional f then pure False else keyLike (fieldType f)) fs
  _ -> pure False

hasRequiredField :: NodeId -> Name -> Build Bool
hasRequiredField i name = getNode i >>= \n -> case n of
  Record fs -> pure $ case find ((== name) . fieldName) fs of
    Just f -> not (fieldOptional f)
    Nothing -> False
  AlternativeNode _ bs -> and <$> mapM (\b -> hasRequiredField (branchType b) name) bs
  _ -> pure False

checkRoot :: Name -> Build ()
checkRoot rootName = do
  rootId <- gets (M.lookup rootName . builtNames) >>= maybe (raise ("root type not found: " ++ rootName)) pure
  getNode rootId >>= \n -> case n of
    Record fs -> forM_ fs $ \f -> do
      wrapper <- getNode (fieldType f)
      childId <- case wrapper of
        Many child -> pure child
        Distinct _ child -> pure child
        _ -> raise ("root field " ++ fieldName f ++ " must be a collection")
      names <- gets builtNames
      let candidates = [name | (name, ident) <- M.toList names, ident == childId]
      case candidates of
        [name] -> do
          child <- getNode childId
          case child of
            Record childFields
              | any fieldKey childFields -> pure ()
              | otherwise -> raise ("root population " ++ fieldName f
                  ++ " targets " ++ name ++ " without a declared key")
            _ -> raise ("root population " ++ fieldName f
                ++ " must contain a keyed object")
        [] -> raise ("root population " ++ fieldName f
            ++ " must contain a named keyed type")
        _ -> raise ("root population " ++ fieldName f
            ++ " is ambiguous between named types " ++ show candidates)
    _ -> raise "root ontology type must be an object"

validateSemanticKeys :: Name -> Build ()
validateSemanticKeys rootName = do
  rootId <- gets (M.lookup rootName . builtNames)
    >>= maybe (raise ("root type not found: " ++ rootName)) pure
  rootNode <- getNode rootId
  let rootCollections = case rootNode of
        Record fs -> S.fromList (map fieldType fs)
        _ -> S.empty
  names <- gets builtNames
  forM_ (M.toList names) $ \(name, nodeId) -> do
    node <- getNode nodeId
    case node of
      Record fs ->
        forM_ [f | f <- fs, fieldKey f] $ \f -> do
          ok <- keyLike (fieldType f)
          unless ok $
            raise ("key field " ++ name ++ "." ++ fieldName f
              ++ " must be a finite keyable value")
      _ -> pure ()

  allNodes <- gets builtNodes
  forM_ (M.toList allNodes) $ \(nodeId, node) ->
    case node of
      Ref target -> requireTargetKey target
      Distinct _ child
        | S.member nodeId rootCollections -> pure ()
        | otherwise -> do
            ok <- keyLike child
            unless ok $
              raise "set element must be a finite keyable value; use a map with an explicit key for structured relational values"
      FunctionNode params _ ->
        forM_ params $ \p -> do
          ok <- keyLike (parameterType p)
          unless ok $
            raise ("map parameter " ++ parameterName p ++ " must be a finite keyable value")
      _ -> pure ()
  where
    requireTargetKey target = do
      targetId <- gets (M.lookup target . builtNames)
        >>= maybe (raise ("reference target is not declared: " ++ target)) pure
      targetNode <- getNode targetId
      case targetNode of
        Record fs
          | any fieldKey fs -> pure ()
          | otherwise ->
              raise ("reference target " ++ target ++ " has no declared key")
        _ ->
          raise ("reference target " ++ target
            ++ " must be an object with a declared key")

checkOntology :: Name -> Module -> Either String Ontology
checkOntology rootName m@(Module ds) = do
  finalState <- execStateT
    (mapM_ (resolveName m) (M.keys ds)
      >> checkRoot rootName
      >> validateSemanticKeys rootName)
    emptyState
  pure (Ontology (builtNames finalState) (builtNodes finalState))

ontologySummary :: Ontology -> String
ontologySummary o = unlines
  [ name ++ " = #" ++ show i ++ " " ++ maybe "<missing>" nodeSummary (M.lookup i (nodes o))
  | (name,i) <- M.toAscList (namedNodes o)
  ]

