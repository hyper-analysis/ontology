module Main (main) where

import Control.Monad (unless)
import qualified Data.Map.Strict as M
import Ontology.Check (checkOntology)
import Ontology.Parser (parseModule, parseModuleFile)
import qualified Ontology.Postgres as P
import qualified Ontology.Relational as R
import Ontology.Syntax
import qualified Postgres.Physical as Physical
import SQL.Render (renderProgram)
import System.Exit (die)

assert :: Bool -> String -> IO ()
assert ok message = unless ok (die message)

lookupNamed :: Ontology -> Name -> IO Node
lookupNamed ontology name =
  case M.lookup name (namedNodes ontology) >>= (\nodeId -> M.lookup nodeId (nodes ontology)) of
    Just node -> pure node
    Nothing -> die ("missing named node " ++ name)

lookupField :: Ontology -> Name -> Name -> IO Field
lookupField ontology typeName wanted = do
  node <- lookupNamed ontology typeName
  case node of
    Record fields ->
      case filter ((== wanted) . fieldName) fields of
        [field] -> pure field
        _ -> die ("missing field " ++ typeName ++ "." ++ wanted)
    _ -> die (typeName ++ " is not a record")

expectRejected :: String -> String -> IO ()
expectRejected label source =
  case parseModule label source >>= checkOntology "Root" of
    Left _ -> pure ()
    Right _ -> die (label ++ " should have been rejected")

expectAccepted :: String -> String -> IO Ontology
expectAccepted label source =
  either die pure (parseModule label source >>= checkOntology "Root")

main :: IO ()
main = do
  parsed <- parseModuleFile "examples/tutoring-company.ontology"
  syntax <- either die pure parsed
  ontology <- either die pure (checkOntology "TutoringCompany" syntax)

  person <- lookupNamed ontology "Person"
  assert (case person of
    Record fields -> any ((== "reference") . fieldName) fields
    _ -> False)
    "Person must be a keyed object boundary"

  personReference <- lookupField ontology "Person" "reference"
  assert (fieldKey personReference)
    "Person.reference must be an explicit semantic key"

  schoolYearStart <- lookupField ontology "SchoolYear" "startYear"
  assert (fieldKey schoolYearStart)
    "SchoolYear.startYear must be an explicit semantic key"
  assert (not (fieldUnique schoolYearStart))
    "key and unique must remain distinct annotations"

  parentEmail <- lookupField ontology "ParentAccount" "email"
  assert (fieldKey parentEmail)
    "ParentAccount.email must be its semantic key"

  relation <- either die pure (R.relational "TutoringCompany" ontology)

  assert (M.keysSet (R.populations relation)
          == M.keysSet
               (M.fromList
                 [ ("ParentAccount", ())
                 , ("Person", ())
                 , ("SchoolYear", ())
                 , ("SessionProgram", ())
                 ]))
    "relational populations must be the keyed root/reference entities"

  personPopulation <-
    maybe (die "missing Person population") pure
      (M.lookup "Person" (R.populations relation))

  assert (case R.populationKey personPopulation of
    [R.KeyColumn [R.Field "reference"] (R.ScalarAtom TString)] -> True
    _ -> False)
    "Person semantic key must lower to the explicitly selected whole field"

  yearPopulation <-
    maybe (die "missing SchoolYear population") pure
      (M.lookup "SchoolYear" (R.populations relation))

  assert (case R.populationKey yearPopulation of
    [R.KeyColumn [R.Field "startYear"] (R.ScalarAtom TNumber)] -> True
    _ -> False)
    "SchoolYear semantic key must be finite and explicit"

  teacherSubjects <- lookupField ontology "Teacher" "teachingSubjects"
  subjectsNode <-
    maybe (die "missing teachingSubjects node") pure
      (M.lookup (fieldType teacherSubjects) (nodes ontology))

  assert (case subjectsNode of
    Distinct [] _ -> True
    _ -> False)
    "ordinary [] collections must canonicalize to sets"

  teacherMeaning <- either die pure (R.lowerNamed ontology "Teacher")
  subjectsMeaning <-
    case [dependent | dependent <- R.dependents teacherMeaning,
                      R.dependentPath dependent == [R.Field "teachingSubjects", R.Elements]] of
      [dependent] -> pure dependent
      _ -> die "missing teachingSubjects set meaning"

  assert (R.boundary subjectsMeaning == R.CollectionBoundary R.DistinctWhole)
    "ordinary collections must have set semantics"
  assert (case R.addedKey subjectsMeaning of
    [R.KeyColumn [] (R.EnumAtom _)] -> True
    _ -> False)
    "set member identity must be the member value, not an occurrence number"

  _ <- expectAccepted "whole-object-key"
    "type K = { a: string; b: number; }; type E = { key k: K; value: string; }; type Root = { es: E[]; };"

  nested <- expectAccepted "nested-key-idempotence"
    "type K = { key a: string; b: number; }; type E = { key k: K; }; type Root = { es: E[]; };"
  nestedPopulation <- either die pure (R.relational "Root" nested)
  ePopulation <-
    maybe (die "missing E population") pure
      (M.lookup "E" (R.populations nestedPopulation))
  assert (case R.populationKey ePopulation of
    [ R.KeyColumn [R.Field "k", R.Field "a"] (R.ScalarAtom TString)
      , R.KeyColumn [R.Field "k", R.Field "b"] (R.ScalarAtom TNumber)
      ] -> True
    _ -> False)
    "outer key must select the whole object; nested key annotations must not narrow it"

  expectRejected "nested-key-does-not-bubble"
    "type K = { key a: string; b: number; }; type E = { k: K; }; type Holder = { e: Ref<E>; }; type Root = { es: E[]; holders: Holder[]; };"

  expectRejected "reference-without-key"
    "type E = { name: string; }; type Holder = { e: Ref<E>; }; type Root = { es: E[]; holders: Holder[]; };"

  expectRejected "key-collection"
    "type E = { key values: string[]; }; type Root = { es: E[]; };"

  expectRejected "set-of-relational-values"
    "type Child = { values: string[]; }; type Root = { children: Child[]; };"

  _ <- expectAccepted "map-instead-of-relational-set"
    "type Child = { values: string[]; }; type Owner = { key name: string; children: (name: string) => Child; }; type Root = { owners: Owner[]; };"

  pg <- either die pure (P.postgres relation)

  peoplePg <-
    case [table | table <- P.pgTables pg, P.pgSemanticPath table == ["people"]] of
      [table] -> pure table
      _ -> die "missing PostgreSQL people table"

  assert (P.pgPrimaryKey peoplePg == ["id"])
    "surrogate SQL identity may remain an internal physical primary key"
  assert (any ((== ["reference"]) . P.pgUniqueFields) (P.pgUnique peoplePg))
    "the semantic Person key must be enforced independently of the physical id"

  subjectTables <-
    pure [table | table <- P.pgTables pg,
                 P.pgSemanticPath table
                   == ["people","details","enrollmentType_Teacher","teachingSubjects","items"]]
  case subjectTables of
    [table] ->
      assert ("value" `elem` P.pgPrimaryKey table)
        "set value must participate directly in the physical row key"
    _ ->
      die "missing teachingSubjects PostgreSQL set table"

  let sql = renderProgram (Physical.program pg)
  assert (not (null sql)) "complete SQL program must render"
  assert ("CREATE TABLE" `contains` sql) "SQL program must create tables"

  putStrLn
    ("Identity/set semantics passed; canonical nodes: "
      ++ show (M.size (nodes ontology))
      ++ "; PostgreSQL tables: "
      ++ show (length (P.pgTables pg)))
  where
    contains needle haystack =
      any (needle `prefixOf`) (tails haystack)

    tails [] = [[]]
    tails xs@(_:rest) = xs : tails rest

    prefixOf prefix value =
      take (length prefix) value == prefix

