module Main (main) where

import Control.Monad (unless)
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Ratio ((%))
import Ontology.Check (checkOntology)
import Ontology.Parser (parseModule)
import qualified Ontology.Postgres as P
import qualified Ontology.Relational as R
import qualified Postgres.Mapping as M
import qualified Postgres.Physical as Physical
import qualified SQL.Query as Q
import qualified SQL.Reference as Ref
import qualified SQL.Render as Render
import qualified SQL.Syntax as S
import SQL.Validate (validateQuery)
import System.Exit (die)
import System.IO (hPutStrLn, stderr)

right :: Either String a -> IO a
right = either die pure

assert :: String -> Bool -> IO ()
assert message condition = unless condition (die ("FAIL: " ++ message))

fails :: Either String a -> Bool
fails (Left _) = True
fails _ = False

scalar :: S.Value -> S.Query
scalar value = S.SelectQuery (S.Output "value" value :| []) Nothing (S.And []) False []

json :: S.JsonExpr -> S.Query
json = S.ValueQuery

emit :: String -> String -> S.Query -> IO ()
emit name expected query = do
  metadata <- right (Render.renderCheckedQuery (json (S.JsonObject
    [("case", S.JsonScalar (S.TextValue name)),
     ("expected", S.JsonScalar (S.CastValue (S.TextValue expected) S.SqlJsonb))])))
  command <- right (Render.renderCheckedQuery query)
  putStr metadata
  putStr command

emitError :: String -> S.RuntimeFailure -> S.Query -> IO ()
emitError name failure query = do
  metadata <- right (Render.renderCheckedQuery (json (S.JsonObject
    [("case", S.JsonScalar (S.TextValue name)), ("expected", S.JsonScalar (S.BoolValue True))])))
  command <- right (Render.renderCheckedQuery query)
  let body = take (length command - 2) command
  putStr metadata
  putStrLn ("DO $test$ DECLARE detail text; BEGIN BEGIN PERFORM (" ++ body
    ++ "); RAISE EXCEPTION USING ERRCODE='XX000',MESSAGE='expected failure';"
    ++ " EXCEPTION WHEN SQLSTATE 'P0001' THEN GET STACKED DIAGNOSTICS detail=MESSAGE_TEXT;"
    ++ " IF detail <> '" ++ show failure ++ "' THEN RAISE EXCEPTION 'wrong runtime failure: %',detail; END IF;"
    ++ " END; END; $test$; SELECT to_jsonb(true);")

field :: M.BoundTable -> String -> IO S.Value
field table name = right (M.columnAt table [R.Field name])

main :: IO ()
main = do
  ontology <- right (parseModule "backend-fixture" ontologySource >>= checkOntology "Root")
  meaning <- right (R.relational "Root" ontology)
  schema <- right (P.postgres meaning)
  p <- right (M.bindAt schema ("Person", []) "p")
  r <- right (M.bindAt schema ("Person", [R.Field "role", R.Branch "role" "Resident"]) "r")
  v <- right (M.bindAt schema ("Person", [R.Field "role", R.Branch "role" "Visitor"]) "v")
  m <- right (M.bindAt schema ("Person", []) "m")
  name <- field p "name"
  city <- field r "city"
  destination <- field v "destination"
  mentorName <- field m "name"
  tag <- right (M.columnAt p [R.Field "role", R.TagName "role"])
  present <- right (M.presenceAt r [R.Field "mentor"])
  ownerR <- right (M.ownerCondition r p)
  ownerV <- right (M.ownerCondition v p)
  mentor <- right (M.referenceCondition r [R.Field "mentor"] m)
  let resident = S.Equals tag (S.TextValue "Resident")
      visitor = S.Equals tag (S.TextValue "Visitor")
      from = S.Join S.LeftJoin
        (S.Join S.LeftJoin
          (S.Join S.LeftJoin (S.Stored (M.binding p)) (S.Stored (M.binding r)) (S.And [ownerR, resident]))
          (S.Stored (M.binding v)) (S.And [ownerV, visitor]))
        (S.Stored (M.binding m)) (S.And [S.BooleanValue present, mentor])
      details = S.CaseValue
        ((resident, S.JsonValue (S.JsonObject [("city", S.JsonScalar city), ("mentor", S.JsonScalar mentorName)])) :| [])
        (S.JsonValue (S.JsonObject [("destination", S.JsonScalar destination)]))
      condition = S.Or [S.And [resident, S.Equals city (S.TextValue "Paris")],
                        S.And [visitor, S.Equals destination (S.TextValue "Paris")]]
      medium = S.SelectQuery (S.Output "name" name :| [S.Output "details" details])
        (Just from) condition True [name]
      mediumArray = S.SelectQuery
        (S.Output "value" (S.Coalesce
          (S.JsonAggregate (S.RowValue "result") [S.OutputColumn "result" "name"]
           :| [S.JsonValue (S.JsonArray (S.SelectQuery (S.Output "value" S.NullValue :| []) Nothing (S.Or []) False []))])) :| [])
        (Just (S.Derived "result" S.Independent medium)) (S.And []) False []
      cities distinctness = S.SelectQuery (S.Output "value" (S.JsonValue (S.JsonScalar city)) :| [])
        (Just (S.Join S.InnerJoin (S.Stored (M.binding p)) (S.Stored (M.binding r)) ownerR))
        (S.Equals city (S.TextValue "Paris")) distinctness []
      noValues = S.SelectQuery (S.Output "value" (S.JsonValue S.JsonNull) :| []) Nothing (S.Or []) False []
      oneNull = scalar (S.JsonValue S.JsonNull)
  structuralTests schema p name city medium
  putStrLn "CREATE SCHEMA sql_backend; SET search_path TO sql_backend;"
  putStr (Render.renderProgram (Physical.program schema))
  putStrLn (Render.renderStatement (S.CreateFailureFunction "query_failure"))
  fixture p r v
  emit "medium query: mapped joins, heterogeneous CASE, optional mentor, row-to-JSON" 
    "[{\"name\":\"alice\",\"details\":{\"city\":\"Paris\",\"mentor\":\"bob\"}},{\"name\":\"claire\",\"details\":{\"destination\":\"Paris\"}},{\"name\":\"emma\",\"details\":{\"city\":\"Paris\",\"mentor\":null}}]"
    (json (S.JsonOne mediumArray))
  emit "distinct projected values" "[\"Paris\"]" (json (S.JsonArray (cities True)))
  emit "empty JSON array" "[]" (json (S.JsonArray noValues))
  emit "generic JsonOne: missing row is null" "null" (json (S.JsonOne noValues))
  emit "unique projected city" "true" (json (S.JsonScalar (S.ConditionValue (Q.uniqueQuery "counted" (cities True)))))
  emit "two source witnesses are not unique without DISTINCT" "false" (json (S.JsonScalar (S.ConditionValue (Q.uniqueQuery "counted" (cities False)))))
  emit "empty result is not unique" "false" (json (S.JsonScalar (S.ConditionValue (Q.uniqueQuery "counted" noValues))))
  emit "one projected null counts as one value" "true" (json (S.JsonScalar (S.ConditionValue (Q.uniqueQuery "counted" oneNull))))
  single <- right (Q.exactlyOne "query_failure" "selected" "aggregated" (cities True))
  emit "exactly one distinct city" "\"Paris\"" (json single)
  nullSingle <- right (Q.exactlyOne "query_failure" "selected" "aggregated" oneNull)
  emit "exactly one null returns null" "null" (json nullSingle)
  none <- right (Q.exactlyOne "query_failure" "selected" "aggregated" noValues)
  emitError "single-result zero rows fails" S.CardinalityFailure (json none)
  multiple <- right (Q.exactlyOne "query_failure" "selected" "aggregated" (cities False))
  emitError "single-result multiple rows fails" S.CardinalityFailure (json multiple)
  emit "exact decimal literal" "123456789.01234567890123456789"
    (json (S.JsonScalar (S.DecimalValue 12345678901234567890123456789 (-20))))
  emit "legacy rational literal also avoids Double conversion" "0.12345678901234567890123456789"
    (json (S.JsonScalar (S.NumberValue (12345678901234567890123456789 % (10 ^ (29 :: Integer))))))
  emit "null-safe equality" "true" (json (S.JsonScalar (S.ConditionValue (S.NullSafeEquals S.NullValue S.NullValue))))
  emit "ordered comparison and Boolean CASE" "7"
    (json (S.JsonScalar (S.CaseValue ((S.Compare S.Less (S.DecimalValue 1 0) (S.DecimalValue 2 0), S.DecimalValue 7 0) :| []) (S.DecimalValue 9 0))))
  emit "inactive failure branch is not executed" "\"ok\""
    (json (S.JsonScalar (S.CaseValue ((S.And [], S.TextValue "ok") :| []) (S.FailureValue "query_failure" S.MissingValue S.SqlText))))
  emitError "active missing-value failure" S.MissingValue
    (json (S.JsonScalar (S.CaseValue ((S.Or [], S.TextValue "ok") :| []) (S.FailureValue "query_failure" S.MissingValue S.SqlText))))
  emitError "unique predicate propagates a projected failure" S.MissingValue
    (json (S.JsonScalar (S.ConditionValue (Q.uniqueQuery "counted"
      (scalar (S.FailureValue "query_failure" S.MissingValue S.SqlJsonb))))))
  emit "count distinct scalar values" "3"
    (json (S.JsonOne (S.SelectQuery (S.Output "value" (S.CountDistinct name) :| [])
      (Just from) condition False [])))
  emit "general JSON array ordering is inside the aggregate"
    "[\"alice\",\"bob\",\"claire\",\"dan\",\"emma\"]"
    (json (S.JsonArray (S.SelectQuery (S.Output "value" name :| [])
      (Just (S.Stored (M.binding p))) (S.And []) False [name])))
  lateral <- lateralQuery p name
  emit "lateral derived source retains outer binding" "[\"alice\"]" (json (S.JsonArray lateral))
  capture <- aliasCaptureQuery schema
  emit "internal JSON alias does not capture an outer reference" "\"alice\"" (json (S.JsonOne capture))
  emit "general query existence" "false" (json (S.JsonScalar (S.ConditionValue (S.ExistsQuery noValues))))
  emit "quoted strings remain data" "\"O'Reilly\\\\book\"" (json (S.JsonScalar (S.TextValue "O'Reilly\\book")))
  hPutStrLn stderr "SQL backend scope/reference/rendering checks passed; emitted executable PostgreSQL fixtures."

structuralTests :: P.PgSchema -> M.BoundTable -> S.Value -> S.Value -> S.Query -> IO ()
structuralTests schema p name city medium = do
  sql <- right (Render.renderCheckedQuery medium)
  assert "general query has DISTINCT, left joins and CASE"
    (all (`isInfixOf` sql) ["SELECT DISTINCT", "LEFT JOIN", "CASE", "jsonb_build_object"])
  assert "actual generated table names come from storage metadata"
    (Ref.physicalTableName (Ref.usedTable (M.binding p)) `isInfixOf` sql)
  assert "unknown physical column rejected" (fails (Ref.columnReference (M.binding p) "invented"))
  assert "unknown semantic field rejected" (fails (M.columnAt p [R.Field "invented"]))
  assert "wrong field ownership rejected by scope validation"
    (fails (validateQuery (S.SelectQuery (S.Output "bad" city :| []) (Just (S.Stored (M.binding p))) (S.And []) False [])))
  assert "duplicate source aliases rejected"
    (fails (validateQuery (S.SelectQuery (S.Output "name" name :| [])
      (Just (S.Cross (S.Stored (M.binding p)) (S.Stored (M.binding p)))) (S.And []) False [])))
  assert "unbound derived column rejected" (fails (validateQuery (scalar (S.OutputColumn "absent" "value"))))
  assert "missing derived output rejected" (fails (validateQuery (S.SelectQuery (S.Output "bad" (S.OutputColumn "q" "missing") :| [])
      (Just (S.Derived "q" S.Independent (scalar S.NullValue))) (S.And []) False [])))
  let correlated = S.SelectQuery (S.Output "value" name :| []) Nothing (S.And []) False []
      invalid = S.SelectQuery (S.Output "value" (S.OutputColumn "q" "value") :| [])
        (Just (S.Cross (S.Stored (M.binding p)) (S.Derived "q" S.Independent correlated))) (S.And []) False []
  assert "independent derived source cannot see preceding sibling" (fails (validateQuery invalid))
  let valid = S.SelectQuery (S.Output "value" (S.OutputColumn "q" "value") :| [])
        (Just (S.Cross (S.Stored (M.binding p)) (S.Derived "q" S.Lateral correlated))) (S.And []) False []
  assert "lateral source can see preceding sibling" (not (fails (validateQuery valid)))
  let multi = S.SelectQuery (S.Output "a" S.NullValue :| [S.Output "b" S.NullValue]) Nothing (S.And []) False []
  assert "scalar subquery needs one output" (fails (validateQuery (scalar (S.ScalarQuery multi))))
  assert "JSON consumer needs one output" (fails (validateQuery (json (S.JsonArray multi))))
  assert "duplicate outputs rejected" (fails (validateQuery (S.SelectQuery (S.Output "a" S.NullValue :| [S.Output "a" S.NullValue]) Nothing (S.And []) False [])))
  assert "parameter indices are validated" (fails (validateQuery (scalar (S.ParameterValue 0))))
  let exact = Render.renderQuery (json (S.JsonScalar (S.DecimalValue 1234567890123456789 (-20))))
  assert "exact decimal renderer preserves coefficient" ("1234567890123456789e-20" `isInfixOf` exact)
  wrong <- right (M.bindAt schema ("Person", []) "wrong")
  assert "owner relation requires actual foreign-key target" (fails (M.ownerCondition p wrong))

lateralQuery :: M.BoundTable -> S.Value -> IO S.Query
lateralQuery p name = pure $ S.SelectQuery (S.Output "value" (S.OutputColumn "q" "personName") :| [])
  (Just (S.Join S.LeftJoin (S.Stored (M.binding p))
    (S.Derived "q" S.Lateral (S.SelectQuery (S.Output "personName" name :| []) Nothing (S.And []) False [])) (S.And [])))
  (S.Equals name (S.TextValue "alice")) False []

aliasCaptureQuery :: P.PgSchema -> IO S.Query
aliasCaptureQuery schema = do
  outer <- right (M.bindAt schema ("Person", []) "__json_one")
  name <- field outer "name"
  let inner = S.SelectQuery (S.Output "value" name :| []) Nothing (S.And []) False []
  pure (S.SelectQuery (S.Output "value" (S.JsonValue (S.JsonOne inner)) :| [])
    (Just (S.Stored (M.binding outer))) (S.Equals name (S.TextValue "alice")) False [])

fixture :: M.BoundTable -> M.BoundTable -> M.BoundTable -> IO ()
fixture p r v = do
  let table = (\n -> "\"" ++ n ++ "\"") . Ref.physicalTableName . Ref.usedTable . M.binding
  putStrLn "BEGIN;"
  putStrLn ("INSERT INTO " ++ table p ++ " (id,name,role_role) OVERRIDING SYSTEM VALUE VALUES "
    ++ "(1,'alice','Resident'),(2,'bob','Resident'),(3,'claire','Visitor'),(4,'dan','Visitor'),(5,'emma','Resident');")
  putStrLn ("INSERT INTO " ++ table r ++ " (id,city,__present_mentor,mentor) VALUES (1,'Paris',true,2),(2,'Lyon',false,NULL),(5,'Paris',false,NULL);")
  putStrLn ("INSERT INTO " ++ table v ++ " (id,destination) VALUES (3,'Paris'),(4,'Rome');")
  putStrLn "COMMIT;"

ontologySource :: String
ontologySource = unlines
  [ "type Resident = { city: string; mentor?: Ref<Person>; };"
  , "type Visitor = { destination: string; };"
  , "type Role = alternative role { Resident: Resident; Visitor: Visitor; };"
  , "type Person = { key name: string; role: Role; };"
  , "type Root = { people: Person[]; };"
  ]

