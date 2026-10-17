-- Small algebraic query builders; no schema/view dependency and no SQL text.
module SQL.Query
  ( outputs, singleOutput, countQuery, uniqueQuery, exactlyOne, freshAlias
  ) where

import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import qualified SQL.Reference as Ref
import SQL.Syntax

outputs :: Query -> NonEmpty Name
outputs (Query {}) = "value" :| []
outputs (ValueQuery _) = "value" :| []
outputs (SelectQuery fields _ _ _ _) = fmap (\(Output name _) -> name) fields

singleOutput :: Query -> Either String Name
singleOutput query = case NE.toList (outputs query) of
  [name] -> Right name
  _ -> Left "Scalar/JSON query consumer requires exactly one projected column"

countQuery :: Alias -> Query -> Query
countQuery alias query = SelectQuery
  (Output "count" (CountValue (JsonValue (JsonScalar (RowValue alias)))) :| [])
  (Just (Derived alias Lateral query)) (And []) False []

uniqueQuery :: Alias -> Query -> Expr
uniqueQuery alias query = Equals (ScalarQuery (countQuery alias query)) (NumberValue 1)

-- The source query supplies one value column, serialized as JSON. Deduplication, if
-- wanted, is explicit on that source. COUNT(*) counts a projected null as a row.
-- Aggregate once; inspect the count and payload in an outer query.
exactlyOne :: Name -> Alias -> Alias -> Query -> Either String JsonExpr
exactlyOne failureFunction sourceAlias aggregateAlias query = do
  name <- singleOutput query
  let aggregate = SelectQuery
        (Output "count" CountRows :| [Output "values" (JsonAggregate (OutputColumn sourceAlias name) [])])
        (Just (Derived sourceAlias Lateral query)) (And []) False []
      value = CaseValue
        ((Equals (OutputColumn aggregateAlias "count") (NumberValue 1),
          JsonElement (OutputColumn aggregateAlias "values") 0) :| [])
        (FailureValue failureFunction CardinalityFailure SqlJsonb)
      result = SelectQuery (Output "value" value :| [])
        (Just (Derived aggregateAlias Lateral aggregate)) (And []) False []
  pure (JsonOne result)

-- Include free references as well as binders: renderer-introduced subquery
-- aliases must not capture a correlated outer reference.
queryAliases :: Query -> [Alias]
queryAliases (Query value _ alias condition ordering joins) =
  alias : map snd joins ++ jsonAliases value ++ conditionAliases condition ++ concatMap valueAliases ordering
queryAliases (ValueQuery value) = jsonAliases value
queryAliases (SelectQuery fields source condition _ ordering) =
  concatMap (\(Output _ value) -> valueAliases value) (NE.toList fields)
    ++ maybe [] fromAliases source ++ conditionAliases condition ++ concatMap valueAliases ordering

fromAliases :: From -> [Alias]
fromAliases (JsonItems alias value) = alias : valueAliases value
fromAliases (JsonPairs alias value) = alias : valueAliases value
fromAliases (Stored use) = [Ref.tableAlias use]
fromAliases (Derived alias _ query) = alias : queryAliases query
fromAliases (Cross left right) = fromAliases left ++ fromAliases right
fromAliases (Join _ left right condition) = fromAliases left ++ fromAliases right ++ conditionAliases condition

valueAliases :: Value -> [Alias]
valueAliases (ColumnValue alias _) = maybe [] (:[]) alias
valueAliases (BoundColumn column) = [Ref.tableAlias (Ref.columnTableUse column)]
valueAliases (OutputColumn alias _) = [alias]
valueAliases (RowValue alias) = [alias]
valueAliases (CastValue value _) = valueAliases value
valueAliases (CaseValue arms fallback) = concatMap (\(c,v) -> conditionAliases c ++ valueAliases v) (NE.toList arms) ++ valueAliases fallback
valueAliases (ConditionValue condition) = conditionAliases condition
valueAliases (JsonValue value) = jsonAliases value
valueAliases (ScalarQuery query) = queryAliases query
valueAliases (CountDistinct value) = valueAliases value
valueAliases (CountValue value) = valueAliases value
valueAliases (JsonAggregate value ordering) = valueAliases value ++ concatMap valueAliases ordering
valueAliases (JsonElement value _) = valueAliases value
valueAliases (Coalesce values) = concatMap valueAliases (NE.toList values)
valueAliases (FunctionValue _ values) = concatMap valueAliases values
valueAliases (JsonField value _) = valueAliases value
valueAliases (JsonText value) = valueAliases value
valueAliases (JsonLength value) = valueAliases value
valueAliases (JsonArrayValues values) = concatMap valueAliases values
valueAliases (JsonObjectAggregate key value) = valueAliases key ++ valueAliases value
valueAliases (BoolAggregate _ value) = valueAliases value
valueAliases (ParameterValue _) = []
valueAliases (TextValue _) = []
valueAliases (NumberValue _) = []
valueAliases (BoolValue _) = []
valueAliases NullValue = []
valueAliases (DecimalValue _ _) = []
valueAliases CountRows = []
valueAliases (FailureValue _ _ _) = []

conditionAliases :: Expr -> [Alias]
conditionAliases (Equals left right) = valueAliases left ++ valueAliases right
conditionAliases (IsNull value) = valueAliases value
conditionAliases (IsNotNull value) = valueAliases value
conditionAliases (And conditions) = concatMap conditionAliases conditions
conditionAliases (Or conditions) = concatMap conditionAliases conditions
conditionAliases (Not condition) = conditionAliases condition
conditionAliases (Exists (Select _ alias condition)) = alias : conditionAliases condition
conditionAliases (Compare _ left right) = valueAliases left ++ valueAliases right
conditionAliases (NullSafeEquals left right) = valueAliases left ++ valueAliases right
conditionAliases (BooleanValue value) = valueAliases value
conditionAliases (ExistsQuery query) = queryAliases query

jsonAliases :: JsonExpr -> [Alias]
jsonAliases (JsonScalar value) = valueAliases value
jsonAliases (JsonObject fields) = concatMap (jsonAliases . snd) fields
jsonAliases (JsonArray query) = queryAliases query
jsonAliases (JsonOne query) = queryAliases query
jsonAliases (JsonNullable condition value) = conditionAliases condition ++ jsonAliases value
jsonAliases (JsonCase condition yes no) = conditionAliases condition ++ jsonAliases yes ++ jsonAliases no
jsonAliases (JsonMerge values) = concatMap jsonAliases values
jsonAliases JsonNull = []

freshAlias :: Alias -> Query -> Alias
freshAlias prefix query = head [name | name <- prefix : [prefix ++ "_" ++ show n | n <- [1 :: Integer ..]], name `notElem` queryAliases query]

