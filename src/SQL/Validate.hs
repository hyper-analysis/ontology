-- Scope/shape validation for the restricted SQL query AST. PostgreSQL still
-- checks scalar SQL types and aggregate legality; this is not a SQL type checker.
module SQL.Validate (validateQuery) where

import Control.Monad (unless, when, void)
import Data.List (nub)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as M
import qualified SQL.Reference as Ref
import SQL.Query (outputs, singleOutput)
import SQL.Syntax

data Binding = Physical Ref.TableUse | Projected [Name] | Legacy
  deriving (Eq, Show)
type Scope = M.Map Alias Binding

validateQuery :: Query -> Either String ()
validateQuery = queryIn M.empty

queryIn :: Scope -> Query -> Either String ()
queryIn outer (ValueQuery value) = jsonIn outer value
queryIn outer (Query value table alias condition ordering joins) = do
  mapM_ validIdentifier (table : map fst joins)
  local <- aliases [(a, Legacy) | (_, a) <- (table, alias):joins]
  let scope = local `M.union` outer
  jsonIn scope value
  conditionIn scope condition
  mapM_ (valueIn scope) ordering
queryIn outer query@SelectQuery{} = do
  let names = NE.toList (outputs query)
  unless (length names == length (nub names)) (Left "Duplicate projected output name")
  mapM_ validIdentifier names
  local <- maybe (Right M.empty) (fromIn outer M.empty) (querySource query)
  let scope = local `M.union` outer
  mapM_ (\(Output _ value) -> valueIn scope value) (queryOutputs query)
  conditionIn scope (queryWhere query)
  mapM_ (valueIn scope) (queryOrderBy query)
  when (queryDistinct query) $ mapM_ (orderedOutput (NE.toList (queryOutputs query))) (queryOrderBy query)
  where
    orderedOutput fields value = unless (value `elem` [v | Output _ v <- fields])
      (Left "DISTINCT ordering must use projected expressions")

validIdentifier :: String -> Either String ()
validIdentifier name = unless (not (null name) && '\0' `notElem` name)
  (Left "Empty/NUL SQL identifier")

aliases :: [(Alias, Binding)] -> Either String Scope
aliases entries = do
  mapM_ (validIdentifier . fst) entries
  unless (length entries == length (nub (map fst entries))) (Left "Duplicate SQL alias")
  pure (M.fromList entries)

mergeSources :: Scope -> Scope -> Scope -> Either String Scope
mergeSources outer previous incoming = do
  unless (null [a | a <- M.keys incoming, M.member a previous || M.member a outer])
    (Left "SQL source alias shadows an existing binding")
  pure (incoming `M.union` previous)

fromIn :: Scope -> Scope -> From -> Either String Scope
fromIn outer previous (JsonItems alias value) = jsonSource outer previous alias ["value"] value
fromIn outer previous (JsonPairs alias value) = jsonSource outer previous alias ["key","value"] value
fromIn outer previous (Stored use) = do
  let local = M.singleton (Ref.tableAlias use) (Physical use)
  _ <- mergeSources outer previous local
  pure local
fromIn outer previous (Derived alias correlation query) = do
  validIdentifier alias
  queryIn (case correlation of Independent -> outer; Lateral -> previous `M.union` outer) query
  let local = M.singleton alias (Projected (NE.toList (outputs query)))
  _ <- mergeSources outer previous local
  pure local
fromIn outer previous (Cross left right) = do
  first <- fromIn outer previous left
  second <- fromIn outer (first `M.union` previous) right
  mergeSources outer first second
fromIn outer previous (Join _ left right condition) = do
  first <- fromIn outer previous left
  second <- fromIn outer (first `M.union` previous) right
  local <- mergeSources outer first second
  conditionIn (local `M.union` outer) condition
  pure local

jsonSource :: Scope -> Scope -> Alias -> [Name] -> Value -> Either String Scope
jsonSource outer previous alias names value = do
  validIdentifier alias
  valueIn (previous `M.union` outer) value
  let local = M.singleton alias (Projected names)
  _ <- mergeSources outer previous local
  pure local

findBinding :: Scope -> Alias -> Either String Binding
findBinding scope alias = maybe (Left ("Unbound SQL alias " ++ show alias)) Right (M.lookup alias scope)

columnIn :: Scope -> Alias -> Name -> Either String ()
columnIn scope alias name = do
  binding <- findBinding scope alias
  case binding of
    Physical use -> void (Ref.columnReference use name)
    Projected names -> unless (name `elem` names) (Left ("Unknown projected column " ++ show name))
    Legacy -> validIdentifier name

valueIn :: Scope -> Value -> Either String ()
valueIn scope (ColumnValue (Just alias) name) = columnIn scope alias name
valueIn scope (ColumnValue Nothing name) = do
  validIdentifier name
  unless (M.null scope) (Left "Unqualified column in a checked query")
valueIn _ (ParameterValue index) = unless (index > 0) (Left "SQL parameter indices start at one")
valueIn _ (TextValue value) = unless ('\0' `notElem` value) (Left "NUL text literal")
valueIn _ (NumberValue _) = Right ()
valueIn _ (BoolValue _) = Right ()
valueIn _ NullValue = Right ()
valueIn scope (BoundColumn reference) = do
  let use = Ref.columnTableUse reference
  actual <- findBinding scope (Ref.tableAlias use)
  unless (actual == Physical use) (Left "Stored column belongs to another table binding")
  void (Ref.columnReference use (Ref.physicalColumnName reference))
valueIn scope (OutputColumn alias name) = do
  binding <- findBinding scope alias
  case binding of
    Projected _ -> columnIn scope alias name
    _ -> Left "OutputColumn requires a derived query binding"
valueIn scope (RowValue alias) = void (findBinding scope alias)
valueIn _ (DecimalValue _ _) = Right ()
valueIn scope (CastValue value _) = valueIn scope value
valueIn scope (CaseValue arms fallback) = do
  mapM_ (\(condition, value) -> conditionIn scope condition >> valueIn scope value) arms
  valueIn scope fallback
valueIn scope (ConditionValue condition) = conditionIn scope condition
valueIn scope (JsonValue value) = jsonIn scope value
valueIn scope (ScalarQuery query) = singleOutput query >> queryIn scope query
valueIn _ CountRows = Right ()
valueIn scope (CountValue value) = valueIn scope value
valueIn scope (CountDistinct value) = valueIn scope value
valueIn scope (JsonAggregate value ordering) = valueIn scope value >> mapM_ (valueIn scope) ordering
valueIn scope (JsonElement value _) = valueIn scope value
valueIn scope (Coalesce values) = mapM_ (valueIn scope) values
valueIn _ (FailureValue name _ _) = validIdentifier name

valueIn scope (FunctionValue name values) = validIdentifier name >> mapM_ (valueIn scope) values
valueIn scope (JsonField value name) = valueIn scope value >> unless ('\0' `notElem` name) (Left "NUL JSON field label")
valueIn scope (JsonText value) = valueIn scope value
valueIn scope (JsonLength value) = valueIn scope value
valueIn scope (JsonArrayValues values) = mapM_ (valueIn scope) values
valueIn scope (JsonObjectAggregate key value) = valueIn scope key >> valueIn scope value
valueIn scope (BoolAggregate _ value) = valueIn scope value

conditionIn :: Scope -> Expr -> Either String ()
conditionIn scope (Equals left right) = valueIn scope left >> valueIn scope right
conditionIn scope (IsNull value) = valueIn scope value
conditionIn scope (IsNotNull value) = valueIn scope value
conditionIn scope (And conditions) = mapM_ (conditionIn scope) conditions
conditionIn scope (Or conditions) = mapM_ (conditionIn scope) conditions
conditionIn scope (Not condition) = conditionIn scope condition
conditionIn scope (Exists (Select table alias condition)) =
  conditionIn (M.insert alias Legacy scope) condition <* validIdentifier table
conditionIn scope (Compare _ left right) = valueIn scope left >> valueIn scope right
conditionIn scope (NullSafeEquals left right) = valueIn scope left >> valueIn scope right
conditionIn scope (BooleanValue value) = valueIn scope value
conditionIn scope (ExistsQuery query) = queryIn scope query

jsonIn :: Scope -> JsonExpr -> Either String ()
jsonIn scope (JsonScalar value) = valueIn scope value
jsonIn scope (JsonObject fields) = mapM_ (jsonIn scope . snd) fields
jsonIn scope (JsonArray query) = do
  _ <- singleOutput query
  queryIn scope query
  case query of
    SelectQuery fields _ _ _ ordering ->
      mapM_ (\value -> unless (value `elem` [v | Output _ v <- NE.toList fields])
        (Left "JSON array ordering must use projected expressions")) ordering
    _ -> Right ()
jsonIn scope (JsonOne query) = singleOutput query >> queryIn scope query
jsonIn scope (JsonNullable condition value) = conditionIn scope condition >> jsonIn scope value
jsonIn scope (JsonCase condition yes no) = conditionIn scope condition >> jsonIn scope yes >> jsonIn scope no
jsonIn scope (JsonMerge values) = mapM_ (jsonIn scope) values
jsonIn _ JsonNull = Right ()

