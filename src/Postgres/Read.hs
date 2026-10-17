-- A read is a value. Only the final SQL statement reads database data.
-- The equations in docs/read-equations.md correspond to selectRelation,
-- selectStep, package and projectValue below. No Writer/stateful table cursor.
module Postgres.Read
  ( compileRead, compilePrepared, compileReadWith, compilePreparedWith
  , parameterSqlTypes, Parameters ) where

import Control.Monad (unless, when)
import Data.List (nub, isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Ontology.Center.Graph hiding (edges)
import Ontology.Projection
import Ontology.Views
import Ontology.Labels.Types
import qualified Ontology.Read as I
import qualified Ontology.Relational as R
import qualified Ontology.Syntax as O
import qualified Ontology.Postgres as P
import qualified SQL.Syntax as SQL

type Parameters = [I.Scalar]
type Storage = (R.Relational, P.PgSchema)
type BoundRow = (P.PgTable, SQL.Alias)

-- Rows are the current value's ownership chain, nearest first. They are SQL
-- variables, not fetched values. fresh is only an inherited alias supply;
-- siblings may reuse it in disjoint subqueries, never shadowing an ancestor.
data Scope = Scope
  { scopePoint :: Address
  , scopeRows :: [BoundRow]
  , scopeFresh :: Integer
  }

-- A selector relative to an outer scope: new row binders and their predicates.
-- Empty selectedRows means inline access. It does NOT mean absent data.
data Selection = Selection
  { selectedScope :: Scope
  , selectedRows :: [BoundRow]
  , selectedTests :: [SQL.Expr]
  }

origin :: Address -> P.SemanticOrigin
origin (Address name path) = (name, path)

addressOf :: P.PgTable -> Address
addressOf table = uncurry Address (P.pgValueOrigin table)

populationKeys :: R.Relational -> String -> Either String [R.KeyColumn]
populationKeys meaning name = maybe (Left ("Unknown population " ++ name))
  (Right . R.populationKey) (M.lookup name (R.populations meaning))

parameterSqlTypes :: PreparedView -> [SQL.SqlType]
parameterSqlTypes = map (P.atomType . parameterAtom) . preparedParameters

-- The former API is exactly the technical interpretation, not another compiler.
compilePrepared :: R.Relational -> P.PgSchema -> PreparedView -> Either String SQL.Query
compilePrepared = compilePreparedWith technical

-- Compile the function, not a sample invocation of it. Labeling only reaches
-- the payload equations. Parameters, guards and row selection stay semantic.
compilePreparedWith :: Labeling -> R.Relational -> P.PgSchema -> PreparedView -> Either String SQL.Query
compilePreparedWith labels meaning schema view = do
  let p = preparedProjection view
      point = preparedCenter view
      storage = (meaning, schema)
  unless (point == projectedAddress p && preparedPopulation view == addressPopulation point)
    (Left "Prepared view and projection have different centers")
  signature <- keyParameters (populationKeys meaning) (projectedKey p)
  unless (signature == preparedParameters view) (Left "Prepared view has an inconsistent signature")
  selection <- selectAt schema point 0
  let scope = selectedScope selection
  keyTests <- mapM (parameterTest storage scope) (zip [1..] signature)
  guards <- guardTests schema scope (projectedGuards p)
  value <- projectValue labels storage scope p
  queryFor (selection { selectedTests = selectedTests selection ++ keyTests ++ guards }) value

compileRead :: R.Relational -> P.PgSchema -> I.Read -> Either String (SQL.Query, Parameters)
compileRead = compileReadWith technical

compileReadWith :: Labeling -> R.Relational -> P.PgSchema -> I.Read -> Either String (SQL.Query, Parameters)
compileReadWith labels meaning schema request = do
  let inst = I.readInstance request
      p = I.readProjection request
      point = within (population (I.instancePopulation inst)) (I.readFocus request)
  parameters <- keyParameters (populationKeys meaning) (projectedKey p)
  values <- I.bindArguments parameters (I.instanceArguments inst)
  query <- compilePreparedWith labels meaning schema
    (PreparedView "read" (I.instancePopulation inst) point parameters p)
  pure (query, values)

-- Establish the row for a semantic occurrence plus its existing owners.
selectAt :: P.PgSchema -> Address -> Integer -> Either String Selection
selectAt schema point first = do
  table <- P.tableForValue schema (origin point)
  (bindings, tests, next) <- chain S.empty table first
  pure (Selection (Scope point bindings next) bindings tests)
  where
    chain seen table n = do
      when (S.member (P.pgTableName table) seen) (Left "Cycle in physical ownership metadata")
      let binding = (table, "v" ++ show n)
      case P.pgOwnerReference table of
        Nothing -> pure ([binding], [], n + 1)
        Just reference -> do
          parent <- P.tableNamed schema (P.pgReferenceTarget reference)
          (parents, tests, next) <- chain (S.insert (P.pgTableName table) seen) parent (n + 1)
          parentBinding <- firstRow parents
          equalities <- correlate reference binding parentBinding
          pure (binding:parents, equalities ++ tests, next)

firstRow :: [BoundRow] -> Either String BoundRow
firstRow (x:_) = Right x
firstRow [] = Left "Missing physical row binding"

boundTable :: Scope -> P.PgTable -> Either String BoundRow
boundTable scope table = case [b | b@(t, _) <- scopeRows scope, P.pgValueOrigin t == P.pgValueOrigin table] of
  [b] -> Right b
  _ -> Left ("No unambiguous binding for " ++ show (P.pgValueOrigin table))

atPoint :: P.PgSchema -> Scope -> Address -> Either String Scope
atPoint schema scope point = do
  table <- P.tableForValue schema (origin point)
  _ <- boundTable scope table
  let Address pop prefix = addressOf table
  unless (pop == addressPopulation (scopePoint scope)
          && prefix `isPrefixOf` addressPath (scopePoint scope))
    (Left "Cannot reuse a row outside the current ownership chain")
  -- Forget descendants when moving to an owner. Following its collection
  -- again must enumerate members, not reuse the member we came from.
  pure scope { scopePoint = point
             , scopeRows = dropWhile ((/= P.pgValueOrigin table) . P.pgValueOrigin . fst) (scopeRows scope) }

columnAt :: P.PgSchema -> Scope -> Address -> Either String SQL.Value
columnAt schema scope address = do
  table <- P.tableForValue schema (origin address)
  (_, alias) <- boundTable scope table
  let path = drop (length (snd (P.pgValueOrigin table))) (addressPath address)
  name <- maybe (Left ("No stored value at " ++ show address)) Right (lookup path (P.pgBindings table))
  pure (SQL.ColumnValue (Just alias) name)

presenceAt :: P.PgSchema -> Scope -> Address -> Either String SQL.Value
presenceAt schema scope address = do
  table <- P.tableForValue schema (origin address)
  (_, alias) <- boundTable scope table
  let path = drop (length (snd (P.pgValueOrigin table))) (addressPath address)
  name <- maybe (Left ("No stored presence at " ++ show address)) Right (lookup path (P.pgPresenceBindings table))
  pure (SQL.ColumnValue (Just alias) name)

guardTests :: P.PgSchema -> Scope -> [Guard] -> Either String [SQL.Expr]
guardTests schema scope = mapM one
  where
    one (Present a) = (\v -> SQL.Equals v (SQL.BoolValue True)) <$> presenceAt schema scope a
    one (TagEquals a value) = (\v -> SQL.Equals v (SQL.TextValue value)) <$> columnAt schema scope a

correlate :: P.PgReference -> BoundRow -> BoundRow -> Either String [SQL.Expr]
correlate reference (_, source) (targetTable, target) = do
  let local = P.pgReferenceFields reference
      remote = P.pgReferenceTargetFields reference
  unless (not (null local) && length local == length remote
          && P.pgReferenceTarget reference == P.pgTableName targetTable)
    (Left "Invalid foreign-key correspondence in storage mapping")
  pure [SQL.Equals (SQL.ColumnValue (Just source) a) (SQL.ColumnValue (Just target) b)
       | (a, b) <- zip local remote]

referenceAt :: P.PgSchema -> Scope -> Address -> P.PgTable -> Either String (BoundRow, P.PgReference)
referenceAt schema scope point target = do
  table <- P.tableForValue schema (origin point)
  binding <- boundTable scope table
  value <- columnAt schema scope point
  name <- case value of
    SQL.ColumnValue _ n -> Right n
    _ -> Left "Reference occurrence is not backed by a stored value"
  case [r | r <- P.pgReferences table, P.pgReferenceFields r == [name]
          , P.pgReferenceTarget r == P.pgTableName target] of
    [r] -> Right (binding, r)
    _ -> Left ("No unique foreign key for " ++ show point)

-- S(identity,b) = inline b
-- S(t ; rest,b) = let S(t,b)=(b',rows,where)
--                    S(rest,b')=(b'',rows',where')
--                in (b'', rows ++ rows', where ++ where').
-- One selector is built for the WHOLE relation, so composed plural traversals
-- do not accidentally produce arrays of arrays or discard path witnesses.
selectRelation :: P.PgSchema -> Scope -> Relation -> Either String Selection
selectRelation schema scope relation = do
  unless (scopePoint scope == relationSource relation) (Left "Relation starts at a different semantic point")
  go scope (traversals relation)
  where
    go current [] = Right (Selection current [] [])
    go current (t:ts) = do
      first <- selectStep schema current t
      rest <- go (selectedScope first) ts
      pure (Selection (selectedScope rest)
        (selectedRows first ++ selectedRows rest) (selectedTests first ++ selectedTests rest))

-- Only identity references introduce a new independent object. Even a
-- self-reference to the same SQL table must bind a FRESH row variable.
selectStep :: P.PgSchema -> Scope -> Traversal -> Either String Selection
selectStep schema scope (Traversal direction edge) = do
  let source = if direction == Forward then edgeSource edge else edgeTarget edge
      target = if direction == Forward then edgeTarget edge else edgeSource edge
  unless (scopePoint scope == source) (Left "Traversal source mismatch")
  result <- case edgePrimitive edge of
    Reference _ -> do
      selection <- selectAt schema target (scopeFresh scope)
      let next = selectedScope selection
          (referencingScope, referencedScope) =
            if direction == Forward then (scope, next) else (next, scope)
      targetTable <- P.tableForValue schema (origin (edgeTarget edge))
      targetBinding <- boundTable referencedScope targetTable
      (sourceBinding, fk) <- referenceAt schema referencingScope (edgeSource edge) targetTable
      tests <- correlate fk sourceBinding targetBinding
      pure selection { selectedTests = selectedTests selection ++ tests }
    _ -> do
      targetTable <- P.tableForValue schema (origin target)
      if any ((== P.pgValueOrigin targetTable) . P.pgValueOrigin . fst) (scopeRows scope)
        then do
          next <- atPoint schema scope target
          pure (Selection next [] [])
        else do
          fk <- maybe (Left "Containment boundary has no owner FK") Right (P.pgOwnerReference targetTable)
          parent <- P.tableNamed schema (P.pgReferenceTarget fk)
          parentBinding <- boundTable scope parent
          let newBinding = (targetTable, "v" ++ show (scopeFresh scope))
              parents = dropWhile ((/= P.pgValueOrigin parent) . P.pgValueOrigin . fst) (scopeRows scope)
              next = Scope target (newBinding:parents) (scopeFresh scope + 1)
          tests <- correlate fk newBinding parentBinding
          pure (Selection next [newBinding] tests)
  let guardScope = case edgePrimitive edge of
        Reference _ -> if direction == Forward then scope else selectedScope result
        _ -> if direction == Forward then selectedScope result else scope
  tests <- guardTests schema guardScope (edgeGuards edge)
  pure result { selectedTests = selectedTests result ++ tests }

cardinality :: Relation -> Cardinality
cardinality = relationCardinality

queryFor :: Selection -> SQL.JsonExpr -> Either String SQL.Query
queryFor selection value = case selectedRows selection of
  [] -> Left "An inline selection does not need a SELECT"
  (table, alias):rest -> Right SQL.Query
    { SQL.queryExpression = value
    , SQL.queryFrom = P.pgTableName table, SQL.queryAlias = alias
    , SQL.queryJoins = [(P.pgTableName t, a) | (t, a) <- rest]
    , SQL.queryWhere = SQL.And (selectedTests selection)
    , SQL.queryOrderBy = [SQL.ColumnValue (Just a) k | (t, a) <- selectedRows selection, k <- P.pgPrimaryKey t]
    }

-- Packaging is independent of physical direction and JSON payload construction.
package :: Cardinality -> Selection -> SQL.JsonExpr -> Either String SQL.JsonExpr
package _ selection value | null (selectedRows selection) =
  Right (if null (selectedTests selection) then value else SQL.JsonNullable (SQL.And (selectedTests selection)) value)
package Unbounded selection value = SQL.JsonArray <$> queryFor selection value
package _ selection value = SQL.JsonOne <$> queryFor selection value

-- J_L(connection) = package(S(relation), J_L(child, resulting binding)).
connection :: Labeling -> Storage -> Scope -> Relation -> Projection -> Either String SQL.JsonExpr
connection labels storage@(_, schema) scope relation child = do
  selection <- selectRelation schema scope relation
  unless (scopePoint (selectedScope selection) == projectedAddress child)
    (Left "Relation destination and child projection disagree")
  value <- projectValue labels storage (selectedScope selection) child
  package (cardinality relation) selection value

-- No runtime scalar is substituted into SQL syntax. Each reference-valued key
-- is tested through the referenced population's declared key, not its bigint.
parameterTest :: Storage -> Scope -> (Int, Parameter) -> Either String SQL.Expr
parameterTest (_, schema) scope (index, parameter) = do
  let part = parameterOrigin parameter
  value <- columnAt schema scope (within (keyOwner part) (R.keyPath (keyPart part)))
  followKey (scopeFresh scope) value (parameterReferences parameter)
  where
    followKey _ value [] = Right (SQL.Equals value (SQL.ParameterValue index))
    followKey fresh value ((target, path):rest) = do
      table <- P.tableForValue schema (target, [])
      let alias = "v" ++ show fresh
          targetScope = Scope (population target) [(table, alias)] (fresh + 1)
      targetValue <- columnAt schema targetScope (within (population target) path)
      predicate <- followKey (fresh + 1) targetValue rest
      -- Identity references in this backend point to the population surrogate.
      -- The API supplies only semantic key values; this equality is private.
      unless (P.pgPrimaryKey table == ["id"]) (Left "Unexpected population storage identity")
      pure (SQL.Exists (SQL.Select (P.pgTableName table) alias
        (SQL.And [SQL.Equals (SQL.ColumnValue (Just alias) "id") value, predicate])))

-- The finite display correspondence never rewrites a WHERE predicate. With
-- technical's empty correspondence this reduces to the former JsonScalar.
scalarJSON :: Labeling -> Address -> SQL.Value -> Either String SQL.JsonExpr
scalarJSON labels at raw = do
  options <- choicesAt labels at
  pure (foldr branch (SQL.JsonScalar raw) options)
  where
    branch (literal,caption) rest = SQL.JsonCase
      (SQL.Equals raw (literalValue literal))
      (SQL.JsonScalar (SQL.TextValue caption)) rest
    literalValue (O.TextLiteral s) = SQL.TextValue s
    literalValue (O.NumberLiteral n) = SQL.NumberValue (toRational n)
    literalValue (O.BooleanLiteral b) = SQL.BoolValue b

-- A terminal Ref serializes its semantic key, never the SQL surrogate.
referenceValue :: Labeling -> Storage -> S.Set String -> Scope -> Address -> String -> Either String SQL.JsonExpr
referenceValue labels storage@(meaning, schema) seen scope point target = do
  when (S.member target seen) (Left "Cyclic semantic reference key")
  selection <- selectAt schema (population target) (scopeFresh scope)
  let next = selectedScope selection
  table <- P.tableForValue schema (target, [])
  targetBinding <- boundTable next table
  (sourceBinding, fk) <- referenceAt schema scope point table
  tests <- correlate fk sourceBinding targetBinding
  keys <- populationKeys meaning target
  when (null keys) (Left ("Missing reference key for " ++ target))
  fields <- mapM (keyValue (S.insert target seen) next) keys
  value <- objectPaths labels (population target) fields
  SQL.JsonOne <$> queryFor (selection { selectedTests = selectedTests selection ++ tests }) value
  where
    keyValue visited next key = do
      let at = within (scopePoint next) (R.keyPath key)
      value <- case R.keyAtom key of
        R.ReferenceAtom name -> referenceValue labels storage visited next at name
        _ -> columnAt schema next at >>= scalarJSON labels at
      pure (R.keyPath key, value)

-- Group by SEMANTIC paths first. Translate the resulting keys, never paths.
objectPaths :: Labeling -> Address -> [(R.Path, SQL.JsonExpr)] -> Either String SQL.JsonExpr
objectPaths _ _ [([], value)] = Right value
objectPaths labels at fields = do
  when (any (null . fst) fields) (Left "Scalar and object key shapes overlap")
  let names = nub [s | (s:_, _) <- fields]
  pairs <- mapM (\s -> do
    case s of
      R.Field _ -> pure ()
      R.Argument _ -> pure ()
      _ -> Left "Non-keyable segment in semantic key"
    let next = within at [s]
    name <- nameOf labels (KeyField next Singular)
    child <- objectPaths labels next [(rest, value) | (s':rest, value) <- fields, s' == s]
    pure (name, child)) names
  jsonObject pairs

jsonObject :: [(String, SQL.JsonExpr)] -> Either String SQL.JsonExpr
jsonObject fields = do
  unless (length fields == length (nub (map fst fields))) (Left "Projected JSON labels collide")
  pure (SQL.JsonObject fields)

followed :: [ProjectedConnection] -> [(Relation, Projection)]
followed xs = [(r, p) | Followed r p <- xs]

primitiveOf :: Relation -> Maybe (Direction, Primitive)
primitiveOf r = case traversals r of
  [Traversal d e] -> Just (d, edgePrimitive e)
  _ -> Nothing

-- ONE set of structural JSON equations, parameterized by expression policy.
projectValue :: Labeling -> Storage -> Scope -> Projection -> Either String SQL.JsonExpr
projectValue labels storage@(_, schema) scope p = do
  unless (scopePoint scope == projectedAddress p) (Left "Projection binding mismatch")
  case projectedExpansion p of
    Stopped why -> case projectedKind p of
      Atomic atom -> atomic atom
      _ -> do
        name <- wrapper CutoffMarker
        pure (SQL.JsonObject [(name, SQL.JsonScalar (SQL.TextValue (show why)))])
    Expanded forwards backwards -> do
      let out = followed forwards
          incoming = followed backwards
          arguments = [(r, c) | (r, c) <- out, Just (Forward, Argument _) <- [primitiveOf r]]
          values = [(r, c) | (r, c) <- out, not (isArgument r)]
      value <- contents values incoming
      if null arguments then pure value else do
        keys <- mapM fieldValue arguments >>= jsonObject
        keyName <- wrapper MapKey
        valueName <- wrapper MapValue
        jsonObject [(keyName, keys), (valueName, value)]
  where
    wrapper w = nameOf labels (Structural (scopePoint scope) w)
    atomic (R.ReferenceAtom target) = referenceValue labels storage S.empty scope (scopePoint scope) target
    atomic _ = columnAt schema scope (scopePoint scope) >>= scalarJSON labels (scopePoint scope)
    isArgument r = case primitiveOf r of Just (Forward, Argument _) -> True; _ -> False
    fieldValue (r, child) = do
      name <- nameOf labels (Relationship r (formFor r (projectedKind child)))
      value <- connection labels storage scope r child
      pure (name, value)
    withContext value [] = Right value
    withContext value rs = do
      name <- wrapper ContextValue
      fields <- mapM fieldValue rs
      jsonObject ((name, value):fields)
    contents out incoming = case projectedKind p of
      Atomic atom -> case [(r, c) | (r, c) <- out, Just (Forward, Reference _) <- [primitiveOf r]] of
        [(r, child)] -> connection labels storage scope r child >>= \value -> withContext value incoming
        [] -> atomic atom >>= \value -> withContext value (out ++ incoming)
        _ -> Left "An atomic reference has several forward targets"
      CollectionValue _ -> collection out incoming
      FunctionValue _ -> collection out incoming
      AlternativeValue _ _ -> do
        let branches = [(r, c) | (r, c) <- out, Just (Forward, Variant _ _) <- [primitiveOf r]]
            ordinary = [(r, c) | (r, c) <- out, not (isBranch r)] ++ incoming
        base <- mapM fieldValue ordinary >>= jsonObject
        alternatives <- mapM branchValue branches
        pure (SQL.JsonMerge (base:alternatives))
      RecordValue -> mapM fieldValue (out ++ incoming) >>= jsonObject
    collection [] incoming = withContext (SQL.JsonObject []) incoming
    collection [(r, child)] incoming = connection labels storage scope r child >>= \value -> withContext value incoming
    collection _ _ = Left "Collection has more than one membership relation"
    isBranch r = case primitiveOf r of Just (Forward, Variant _ _) -> True; _ -> False
    branchValue (r, child) = do
      name <- nameOf labels (Relationship r (formFor r (projectedKind child)))
      value <- connection labels storage scope r child
      case primitiveOf r of
        Just (Forward, Variant tag branch) -> do
          tests <- guardTests schema scope [TagEquals (within (scopePoint scope) [R.TagName tag]) branch]
          pure (SQL.JsonCase (SQL.And tests) (SQL.JsonObject [(name, value)]) (SQL.JsonObject []))
        _ -> Left "Expected an alternative relation"

