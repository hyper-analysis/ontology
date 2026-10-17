module SQL.Render
  ( renderProgram, renderStatement, renderQuery, renderPrepared, renderCheckedQuery
  ) where

import Data.List (intercalate)
import qualified Data.List.NonEmpty as NE
import Data.Ratio (numerator, denominator)
import qualified SQL.Reference as Ref
import qualified SQL.Query as Q
import SQL.Syntax
import SQL.Validate (validateQuery)

quoteName :: Name -> String
quoteName name = "\"" ++ concatMap escape name ++ "\""
  where
    escape '"' = "\"\""
    escape c = [c]

quoteText :: String -> String
quoteText value = "E'" ++ concatMap escape value ++ "'"
  where
    escape '\'' = "''"
    escape '\\' = "\\\\"
    escape c = [c]

renderType :: SqlType -> String
renderType SqlText = "text"
renderType SqlBoolean = "boolean"
renderType SqlDouble = "double precision"
renderType SqlTimestamp = "timestamptz"
renderType SqlBigInt = "bigint"
renderType SqlNumeric = "numeric"
renderType SqlJsonb = "jsonb"

renderColumn :: Column -> String
renderColumn c = intercalate " "
  ([quoteName (columnName c), renderType (columnType c)]
    ++ ["GENERATED ALWAYS AS IDENTITY" | columnGeneration c == Identity]
    ++ ["NOT NULL" | columnNullability c == NotNull])

renderNames :: [Name] -> String
renderNames = intercalate ", " . map quoteName

renderConstraint :: Constraint -> String
renderConstraint (PrimaryKey names) = "PRIMARY KEY (" ++ renderNames names ++ ")"
renderConstraint (Unique names equality) =
  "UNIQUE" ++ (if equality == NullsNotDistinct then " NULLS NOT DISTINCT" else "")
    ++ " (" ++ renderNames names ++ ")"
renderConstraint (ForeignKey local target remote deferrability) =
  "FOREIGN KEY (" ++ renderNames local ++ ") REFERENCES " ++ quoteName target
    ++ " (" ++ renderNames remote ++ ")"
    ++ (if deferrability == Deferred then " DEFERRABLE INITIALLY DEFERRED" else "")
renderConstraint (Check condition) = "CHECK (" ++ renderExpr condition ++ ")"

renderValue :: Value -> String
renderValue (ColumnValue Nothing name) = quoteName name
renderValue (ColumnValue (Just alias) name) = quoteName alias ++ "." ++ quoteName name
renderValue (ParameterValue index) = "$" ++ show index
renderValue (TextValue value) = quoteText value
renderValue (NumberValue value) = renderRational (numerator value) (denominator value)
renderValue (BoolValue value) = if value then "TRUE" else "FALSE"
renderValue NullValue = "NULL"
renderValue (BoundColumn value) = quoteName (Ref.tableAlias (Ref.columnTableUse value))
  ++ "." ++ quoteName (Ref.physicalColumnName value)
renderValue (OutputColumn alias name) = quoteName alias ++ "." ++ quoteName name
renderValue (RowValue alias) = quoteName alias
renderValue (DecimalValue coefficient exponentValue) = show coefficient ++ "e" ++ show exponentValue ++ "::numeric"
renderValue (CastValue value ty) = "(" ++ renderValue value ++ ")::" ++ renderType ty
renderValue (CaseValue arms fallback) = "(CASE "
  ++ concat ["WHEN " ++ renderExpr condition ++ " THEN " ++ renderValue value ++ " " | (condition,value) <- NE.toList arms]
  ++ "ELSE " ++ renderValue fallback ++ " END)"
renderValue (ConditionValue condition) = renderExpr condition
renderValue (JsonValue value) = renderJson value
renderValue (ScalarQuery query) = "(" ++ renderQueryBody query ++ ")"
renderValue CountRows = "count(*)"
renderValue (CountValue value) = "count(" ++ renderValue value ++ ")"
renderValue (CountDistinct value) = "count(DISTINCT " ++ renderValue value ++ ")"
renderValue (JsonAggregate value orderingValues) = "jsonb_agg(" ++ renderValue value ++ ordering orderingValues ++ ")"
renderValue (JsonElement value index) = "(" ++ renderValue value ++ " -> " ++ show index ++ ")"
renderValue (Coalesce values) = "COALESCE(" ++ intercalate ", " (map renderValue (NE.toList values)) ++ ")"
renderValue (FailureValue function failure ty) = quoteName function ++ "("
  ++ quoteText (show failure) ++ ", NULL::" ++ renderType ty ++ ")"

renderValue (FunctionValue name values) = quoteName name ++ "(" ++ intercalate ", " (map renderValue values) ++ ")"
renderValue (JsonField value name) = "(" ++ renderValue value ++ " -> " ++ quoteText name ++ ")"
renderValue (JsonText value) = "(" ++ renderValue value ++ " #>> '{}')"
renderValue (JsonLength value) = "jsonb_array_length(" ++ renderValue value ++ ")"
renderValue (JsonArrayValues values) = "jsonb_build_array(" ++ intercalate ", " (map renderValue values) ++ ")"
renderValue (JsonObjectAggregate key value) = "jsonb_object_agg(" ++ renderValue key ++ ", " ++ renderValue value ++ ")"
renderValue (BoolAggregate operation value) = (case operation of AllTrue -> "bool_and"; AnyTrue -> "bool_or")
  ++ "(" ++ renderValue value ++ ")"

renderRational :: Integer -> Integer -> String
renderRational n d =
  let (twos, rest) = factors 2 d
      (fives, remaining) = factors 5 rest
      scale = max twos fives
  in if remaining == 1
     then if scale == 0 then show n
          else show (n * 2 ^ (scale - twos) * 5 ^ (scale - fives)) ++ "e-" ++ show scale
     else "(" ++ show n ++ "::numeric / " ++ show d ++ "::numeric)"

factors :: Integer -> Integer -> (Integer, Integer)
factors prime value
  | value `mod` prime /= 0 = (0, value)
  | otherwise = let (amount, rest) = factors prime (value `div` prime) in (amount + 1, rest)

renderExpr :: Expr -> String
renderExpr (Equals a b) = "(" ++ renderValue a ++ " = " ++ renderValue b ++ ")"
renderExpr (IsNull value) = "(" ++ renderValue value ++ " IS NULL)"
renderExpr (IsNotNull value) = "(" ++ renderValue value ++ " IS NOT NULL)"
renderExpr (And []) = "TRUE"
renderExpr (And xs) = "(" ++ intercalate " AND " (map renderExpr xs) ++ ")"
renderExpr (Or []) = "FALSE"
renderExpr (Or xs) = "(" ++ intercalate " OR " (map renderExpr xs) ++ ")"
renderExpr (Not value) = "(NOT " ++ renderExpr value ++ ")"
renderExpr (Exists s) = "EXISTS (SELECT 1 FROM " ++ quoteName (selectFrom s)
  ++ " AS " ++ quoteName (selectAlias s) ++ " WHERE " ++ renderExpr (selectWhere s) ++ ")"
renderExpr (Compare comparison a b) = "(" ++ renderValue a ++ " " ++ renderComparison comparison ++ " " ++ renderValue b ++ ")"
renderExpr (NullSafeEquals a b) = "(" ++ renderValue a ++ " IS NOT DISTINCT FROM " ++ renderValue b ++ ")"
renderExpr (BooleanValue value) = "(" ++ renderValue value ++ ")"
renderExpr (ExistsQuery query) = "EXISTS (" ++ renderQueryBody query ++ ")"

renderComparison :: Comparison -> String
renderComparison Less = "<"
renderComparison LessEqual = "<="
renderComparison Greater = ">"
renderComparison GreaterEqual = ">="

renderProcedure :: Procedure -> [String]
renderProcedure (If condition body) =
  ["IF " ++ renderExpr condition ++ " THEN"]
    ++ map ("  " ++) (concatMap renderProcedure body) ++ ["END IF;"]
renderProcedure (RaiseConstraint name message) =
  ["RAISE EXCEPTION USING ERRCODE = '23514', CONSTRAINT = " ++ quoteText name
    ++ ", MESSAGE = " ++ quoteText message ++ ";"]
renderProcedure ReturnNull = ["RETURN NULL;"]

renderFunction :: Function -> String
renderFunction f = "CREATE FUNCTION " ++ quoteName (functionName f)
  ++ "() RETURNS trigger LANGUAGE plpgsql AS "
  ++ quoteText ("BEGIN\n" ++ unlines (concatMap renderProcedure (functionBody f)) ++ "END") ++ ";"

renderEvent :: Event -> String
renderEvent Insert = "INSERT"
renderEvent Update = "UPDATE"
renderEvent Delete = "DELETE"

renderTrigger :: Trigger -> String
renderTrigger t = "CREATE CONSTRAINT TRIGGER " ++ quoteName (triggerName t)
  ++ " AFTER " ++ intercalate " OR " (map renderEvent (triggerEvents t))
  ++ " ON " ++ quoteName (triggerTable t)
  ++ (if triggerDeferred t then " DEFERRABLE INITIALLY DEFERRED" else "")
  ++ " FOR EACH ROW EXECUTE FUNCTION " ++ quoteName (triggerFunction t) ++ "();"

renderStatement :: Statement -> String
renderStatement (CreateTable t) = "CREATE TABLE " ++ quoteName (tableName t) ++ " (\n"
  ++ intercalate ",\n" (map (("  " ++) . renderColumn) (tableColumns t)
      ++ map (("  " ++) . renderConstraint) (tableConstraints t)) ++ "\n);"
renderStatement (AlterTableAddConstraint table constraint) =
  "ALTER TABLE " ++ quoteName table ++ " ADD " ++ renderConstraint constraint ++ ";"
renderStatement (CreateFunction f) = renderFunction f
renderStatement (CreateConstraintTrigger t) = renderTrigger t
renderStatement (CreateReadFunction name types query) =
  "CREATE FUNCTION " ++ quoteName name ++ "("
    ++ intercalate ", " [quoteName ("p" ++ show i) ++ " " ++ renderType ty
                        | (i, ty) <- zip [1 :: Int ..] types]
    ++ ") RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER AS "
    ++ quoteText (renderQuery (ValueQuery (JsonOne query))) ++ ";"
renderStatement (CreateFailureFunction name) =
  "CREATE FUNCTION " ++ quoteName name ++ "(message text, exemplar anyelement) RETURNS anyelement "
  ++ "LANGUAGE plpgsql VOLATILE AS "
  ++ quoteText "BEGIN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = message; END;" ++ ";"

-- PL/pgSQL is deliberately not SQL-inlined. Arguments are values evaluated
-- before entry; STABLE retains the calling statement's snapshot for all reads.
renderStatement (CreateValueFunction name types result query) =
  "CREATE FUNCTION " ++ quoteName name ++ "("
    ++ intercalate ", " (map renderType types) ++ ") RETURNS " ++ renderType result
    ++ " LANGUAGE plpgsql STABLE AS "
    ++ quoteText ("BEGIN RETURN (" ++ renderQueryBody query ++ "); END;") ++ ";"

renderProgram :: Program -> String
renderProgram (Program statements) = intercalate "\n\n" (map renderStatement statements) ++ "\n"

renderJson :: JsonExpr -> String
renderJson JsonNull = "'null'::jsonb"
renderJson (JsonScalar NullValue) = renderJson JsonNull
renderJson (JsonScalar (TextValue value)) = "to_jsonb(" ++ quoteText value ++ "::text)"
renderJson (JsonScalar value) = "to_jsonb(" ++ renderValue value ++ ")"
renderJson (JsonObject fields) = "jsonb_build_object("
  ++ intercalate ", " [quoteText name ++ ", " ++ renderJson value | (name, value) <- fields] ++ ")"
renderJson (JsonOne query@SelectQuery{}) = "COALESCE((" ++ renderJsonRows query ++ "), 'null'::jsonb)"
renderJson (JsonOne query) = "COALESCE((" ++ renderQueryBody query ++ "), 'null'::jsonb)"
renderJson (JsonArray (ValueQuery value)) = "jsonb_build_array(" ++ renderJson value ++ ")"
renderJson (JsonArray query@Query{}) =
  "COALESCE((SELECT jsonb_agg(" ++ renderJson (queryExpression query)
    ++ ordering (queryOrderBy query) ++ ")" ++ renderSource query ++ "), '[]'::jsonb)"
renderJson (JsonArray query@SelectQuery{}) =
  let alias = Q.freshAlias "__json_array" query
      name = NE.head (Q.outputs query)
      ordered value = case [n | Output n expression <- NE.toList (queryOutputs query), expression == value] of
        n:_ -> quoteName alias ++ "." ++ quoteName n
        [] -> renderValue value
      aggregateOrder = if null (queryOrderBy query) then "" else " ORDER BY "
        ++ intercalate ", " (map ordered (queryOrderBy query))
  in "COALESCE((SELECT jsonb_agg(" ++ quoteName alias ++ "." ++ quoteName name ++ aggregateOrder ++ ") FROM ("
     ++ renderQueryBody query ++ ") AS " ++ quoteName alias ++ "), '[]'::jsonb)"
renderJson (JsonNullable condition value) = renderJson (JsonCase condition value JsonNull)
renderJson (JsonCase condition yes no) = "(CASE WHEN " ++ renderExpr condition
  ++ " THEN " ++ renderJson yes ++ " ELSE " ++ renderJson no ++ " END)"
renderJson (JsonMerge []) = "'{}'::jsonb"
renderJson (JsonMerge values) = "(" ++ intercalate " || " (map renderJson values) ++ ")"

renderJsonRows :: Query -> String
renderJsonRows query =
  let alias = Q.freshAlias "__json_one" query
      name = NE.head (Q.outputs query)
  in "SELECT to_jsonb(" ++ quoteName alias ++ "." ++ quoteName name ++ ") FROM ("
     ++ renderQueryBody query ++ ") AS " ++ quoteName alias

ordering :: [Value] -> String
ordering [] = ""
ordering values = " ORDER BY " ++ intercalate ", " (map renderValue values)

renderSource :: Query -> String
renderSource (ValueQuery _) = ""
renderSource query@SelectQuery{} = maybe "" ((" FROM " ++) . renderFrom) (querySource query)
  ++ " WHERE " ++ renderExpr (queryWhere query)
renderSource query@Query{} =
  " FROM " ++ intercalate ", "
    [quoteName table ++ " AS " ++ quoteName alias
    | (table, alias) <- (queryFrom query, queryAlias query) : queryJoins query]
  ++ " WHERE " ++ renderExpr (queryWhere query)

renderQueryBody :: Query -> String
renderQueryBody (ValueQuery expression) = "SELECT " ++ renderJson expression ++ " AS value"
renderQueryBody query@SelectQuery{} = "SELECT " ++ (if queryDistinct query then "DISTINCT " else "")
  ++ intercalate ", " [renderValue value ++ " AS " ++ quoteName name | Output name value <- NE.toList (queryOutputs query)]
  ++ renderSource query ++ ordering (queryOrderBy query)
renderQueryBody query@Query{} = "SELECT " ++ renderJson (queryExpression query)
  ++ " AS value" ++ renderSource query ++ ordering (queryOrderBy query)

renderQuery :: Query -> String
renderQuery query = renderQueryBody query ++ ";\n"

renderCheckedQuery :: Query -> Either String String
renderCheckedQuery query = validateQuery query >> pure (renderQuery query)

renderFrom :: From -> String
renderFrom (JsonItems alias value) = "jsonb_array_elements(" ++ renderValue value ++ ") AS " ++ quoteName alias ++ "(value)"
renderFrom (JsonPairs alias value) = "jsonb_each(" ++ renderValue value ++ ") AS " ++ quoteName alias ++ "(key, value)"
renderFrom (Stored use) = quoteName (Ref.physicalTableName (Ref.usedTable use))
  ++ " AS " ++ quoteName (Ref.tableAlias use)
renderFrom (Derived alias correlation query) = (case correlation of Independent -> ""; Lateral -> "LATERAL ")
  ++ "(" ++ renderQueryBody query ++ ") AS " ++ quoteName alias
renderFrom (Cross left right) = "(" ++ renderFrom left ++ " CROSS JOIN " ++ renderFrom right ++ ")"
renderFrom (Join kind left right condition) = "(" ++ renderFrom left
  ++ (case kind of InnerJoin -> " INNER JOIN "; LeftJoin -> " LEFT JOIN ")
  ++ renderFrom right ++ " ON " ++ renderExpr condition ++ ")"

renderPrepared :: Name -> [SqlType] -> Query -> String
renderPrepared name types query = "PREPARE " ++ quoteName name
  ++ (if null types then "" else " (" ++ intercalate ", " (map renderType types) ++ ")")
  ++ " AS\n" ++ renderQuery (ValueQuery (JsonOne query))

