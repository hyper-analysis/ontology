module Main (main) where

import Control.Monad (forM_, unless)
import Data.List (isInfixOf, sort)
import qualified Data.Map.Strict as M
import qualified Ontology.Parser as O
import Ontology.Check (checkOntology)
import qualified Ontology.Syntax as Ontology
import qualified Ontology.Postgres as P
import qualified Ontology.Relational as R
import qualified Postgres.Physical as Physical
import qualified OSQL.Parser as Parser
import qualified OSQL.Check as Check
import qualified OSQL.Compile as Compile
import qualified OSQL.Type as T
import qualified SQL.Syntax as Q
import qualified SQL.Render as Render
import System.Environment (getArgs)
import System.Directory (listDirectory)
import System.FilePath ((</>),takeExtension)
import System.Exit (die)
import System.IO (hPutStrLn, stderr)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (die ("FAIL " ++ message))

right :: Show e => Either e a -> IO a
right = either (die . show) pure

check :: Ontology.Ontology -> String -> IO Check.CheckedProgram
check ontology source = do
  parsed <- either (die . Parser.renderParseError) pure (Parser.parseProgram "test.osql" source)
  either (die . Check.renderDiagnostic) pure (Check.checkProgram "Root" ontology parsed)

ontologyFrom :: FilePath -> IO Ontology.Ontology
ontologyFrom path = readFile path >>= right . (O.parseModule path >=> checkOntology "Root")
  where (>=>) f g value = f value >>= g

main :: IO ()
main = do
  args <- getArgs
  directory <- case args of [] -> pure "docs/o-sql/examples"; [d] -> pure d; _ -> die "Usage: osql-compiler-test [EXAMPLES]"
  fixture <- ontologyFrom (directory </> "fixture.ontology")
  roles <- ontologyFrom (directory </> "roles.ontology")
  checkerTests fixture
  files <- sort . filter ((== ".osql") . takeExtension) <$> listDirectory directory
  forM_ files $ \name -> do
    source <- readFile (directory </> name)
    checked <- check (if name == "complex-roles.osql" then roles else fixture) source
    _ <- right (Compile.compileProgram "published" checked)
    pure ()
  sample <- check fixture "root.people"
  schema <- Compile.compilationSchema <$> right (Compile.compileProgram "sample" sample)
  putStrLn "CREATE SCHEMA osql_fixture; SET search_path TO osql_fixture;"
  putStr (Render.renderProgram (Physical.program schema))
  fixtureData schema
  forM_ (zip [1::Int ..] cases) $ \(n,(name,source,expected)) -> emit fixture n name source expected
  forM_ (zip [100::Int ..] publishedCases) $ \(n,(file,expected)) -> do
    source <- readFile (directory </> file)
    emit fixture n ("published " ++ file) source (Right expected)
  complexSource <- readFile (directory </> "complex-roles.osql")
  complexChecked <- check roles complexSource
  complex <- right (Compile.compileProgram "complex_roles" complexChecked)
  putStrLn "CREATE SCHEMA osql_roles; SET search_path TO osql_roles;"
  putStr (Render.renderProgram (Physical.program (Compile.compilationSchema complex)))
  rolesData (Compile.compilationSchema complex)
  putStr (Render.renderProgram (Compile.compilationSetup complex))
  metadata "published complex roles query" complexExpected
  putStr (Render.renderQuery (Compile.compilationQuery complex))
  structuredKeys
  hPutStrLn stderr ("O-SQL checker/lowering: " ++ show (length files) ++ " published examples and " ++ show (length cases + length publishedCases + 2) ++ " executable result/failure cases.")

checkerTests :: Ontology.Ontology -> IO ()
checkerTests ontology = do
  forM_ invalid $ \(expected,source) -> do
    parsed <- either (die . Parser.renderParseError) pure (Parser.parseProgram "invalid.osql" source)
    case Check.checkProgram "Root" ontology parsed of
      Left diagnostic -> do
        assert ("diagnostic " ++ source) (Check.diagnosticCode diagnostic == expected)
        assert "diagnostic retains source position" ("invalid.osql:1:" `isInfixOf` Check.renderDiagnostic diagnostic)
      Right checked -> die ("Unexpected static acceptance " ++ source ++ " :: " ++ T.prettyType (Check.resultType checked))
  present <- check ontology "root.people(\"alice\").teacher.name"
  optional <- check ontology "root.people(\"alice\")?.teacher?.name"
  assert "strict access has non-null result type and may fail" (Check.resultType present == T.Primitive Ontology.TString)
  assert "optional access adds Null" (T.nullable (Check.resultType optional))
  hetero <- check ontology "match root.people(\"alice\").role { Resident r => r.city; Visitor v => {destination:v.destination}; }"
  assert "match retains heterogeneous result union" $ case Check.resultType hetero of T.Union xs -> length xs == 2; _ -> False
  normalized <- check ontology "match root.people(\"alice\").role { Resident r => {a:1,b:true}; Visitor v => {b:true,a:1.0}; }"
  assert "equivalent records do not erase each other from a union" $ case Check.resultType normalized of T.Record _ -> True; _ -> False
  huge <- check ontology "1e999999999999999999999999999999"
  assert "range restriction is a backend diagnostic" $ case Compile.compileProgram "huge" huge of
    Left (Compile.LoweringError "UnsupportedLowering" _) -> True; _ -> False
  precise <- check ontology "timestamp(\"2026-10-17T12:00:00.1234567Z\")"
  assert "sub-microsecond timestamp remains valid but unsupported by this backend" $ case Compile.compileProgram "precise" precise of
    Left (Compile.LoweringError "UnsupportedLowering" _) -> True; _ -> False
  assert "namespace validation" $ case Compile.compileProgram "not.a.namespace" present of Left _ -> True; _ -> False
  aliasOntology <- right (O.parseModule "aliases.ontology"
    "type Person={key name:string;}; type ZPerson=Person; type Holder={key name:string;friend:Ref<ZPerson>;}; type Root={holders:Holder[];};" >>= checkOntology "Root")
  aliasProgram <- check aliasOntology "root.holders(\"one\").friend.name"
  _ <- right (Compile.compileProgram "aliases" aliasProgram)
  forM_ unsupportedOntologies $ \source -> do
    unsupportedOntology <- right (O.parseModule "unsupported.ontology" source >>= checkOntology "Root")
    program <- check unsupportedOntology "root"
    assert "unsupported catalog produces a separate lowering diagnostic" $ case Compile.compileProgram "unsupported" program of
      Left (Compile.LoweringError "UnsupportedLowering" _) -> True
      _ -> False
  assert "library keeps the ontology graph" (not (M.null (Ontology.nodes ontology)))
  where
    unsupportedOntologies =
      [ "type P={key name:string;};type Root={people?:P[];};"
      , "type A={key b:Ref<B>;};type B={key a:Ref<A>;};type Root={values:A[];};"
      , "type P={key name:string;state:\"x\" | true;};type Root={people:P[];};"
      , "type A={key name:string;};type B=A;type Pair={key name:string;left:Ref<A>;right:Ref<B>;};type Root={pairs:Pair[];};"
      ]
    invalid =
      [ ("UnknownName","alice.city"), ("UnknownField","root.people(\"alice\").unknown")
      , ("UnknownField","root.people(\"alice\")?.unknown"), ("FieldOwner","root.people.city")
      , ("NotCallable","root.people(\"alice\").city(\"x\")")
      , ("ArgumentNames","root.sites(42)"), ("ArgumentNames","root.sites(code:42)")
      , ("ArgumentNames","root.sites(code:42,country:\"FR\",extra:1)")
      , ("ArgumentNames","root.people(name:\"alice\",name:\"bob\")")
      , ("TypeMismatch","root.sites(code:\"wrong\",country:\"FR\")")
      , ("NullShape","root.people(null)"), ("DuplicateBinding","let x=1; let x=2; x")
      , ("DuplicateBinding","select p from root.people as p, root.people as p")
      , ("DuplicateBinding","select p from root.people as p let p=1")
      , ("UnknownName","select x from root.people as p let x=x")
      , ("CollectionType","select p from root.people(\"alice\") as p")
      , ("CollectionType","exist!(select! p from root.people as p)")
      , ("TypeMismatch","select p from root.people as p where p.city")
      , ("TypeMismatch","true and 1"), ("OrderingType","\"a\" < \"b\"")
      , ("EqualityType","{} = 1"), ("EqualityType","1 in root.people")
      , ("SequenceType","first(root.people)"), ("SequenceType","at(root.people,0)")
      , ("DuplicateOutput","{x:1,x:2}"), ("DuplicateOutput","select p as x,p as x from root.people as p")
      , ("MatchType","match root.people(\"alice\") { _ => null; }")
      , ("NonExhaustiveMatch","match root.people(\"alice\").role { Resident r => r.city; }")
      , ("UnknownBranch","match root.people(\"alice\").role { Alien a => null; _ => null; }")
      , ("DuplicateBranch","match root.people(\"alice\").role { Resident r => null; Resident s => null; _ => null; }")
      , ("UnreachableFallback","match root.people(\"alice\").role { Resident r => null; Visitor v => null; _ => null; }")
      , ("UnknownName","select r.city from root.people as p let x=match p.role { Resident r => r.city; Visitor v => null; }")
      , ("MapType","entries(root.people)"), ("CollectionType","count(1)")
      , ("TimestampLiteral","timestamp(\"2026-02-30T12:00:00Z\")")
      , ("TimestampLiteral","timestamp(\"2026-10-17T12:00:60Z\")")
      , ("TimestampLiteral","timestamp(\"2026-10-17T12:00:00-00:00\")")
      , ("TimestampLiteral","timestamp(\"2026-10-17T12:00:00\")")
      ]

metadata :: String -> String -> IO ()
metadata name expected = putStr (Render.renderQuery (Q.ValueQuery (Q.JsonObject
  [("case",Q.JsonScalar (Q.TextValue name)),("expected",Q.JsonScalar (Q.CastValue (Q.TextValue expected) Q.SqlJsonb)),("unordered",Q.JsonScalar (Q.BoolValue True))])))

emit :: Ontology.Ontology -> Int -> String -> String -> Either String String -> IO ()
emit ontology n name source expected = do
  checked <- check ontology source
  compiled <- right (Compile.compileProgram ("case_" ++ show n) checked)
  putStr (Render.renderProgram (Compile.compilationSetup compiled))
  case expected of
    Right value -> do
      metadata name value
      putStr (Render.renderQuery (Compile.compilationQuery compiled))
    Left failure -> do
      metadata name "true"
      let rendered = Render.renderQuery (Compile.compilationQuery compiled)
          body = take (length rendered - 2) rendered
      putStrLn ("DO $test$ DECLARE detail text; BEGIN BEGIN PERFORM (" ++ body
        ++ "); RAISE EXCEPTION USING ERRCODE='XX000',MESSAGE='expected OSQL failure';"
        ++ " EXCEPTION WHEN SQLSTATE 'P0001' THEN GET STACKED DIAGNOSTICS detail=MESSAGE_TEXT;"
        ++ " IF detail <> '" ++ failure ++ "' THEN RAISE EXCEPTION 'wrong OSQL failure: %',detail; END IF;"
        ++ " END; END; $test$; SELECT to_jsonb(true);")

cases :: [(String,String,Either String String)]
cases =
  [ ("keyed field","root.people(\"alice\").city",Right "\"Paris\"")
  , ("missing lookup succeeds with null","root.people(\"nobody\")",Right "null")
  , ("strict traversal fails","root.people(\"nobody\").city",Left "MissingValue")
  , ("optional suffix skips later strict fields","root.people(\"nobody\")?.teacher.name",Right "null")
  , ("present receiver with absent later field still fails","root.people(\"bob\")?.teacher.name",Left "MissingValue")
  , ("optional chain skips failing call arguments","root.people(\"nobody\")?.schooling(year:only((select 2026 from root.people as p where false)),track:\"science\").label",Right "null")
  , ("executed nullable key argument is demanded","root.people(name:root.people(\"nobody\")?.name)",Left "MissingValue")
  , ("multiple dependent sources are ordered","select l.code from root.people as p,p.lessons as l",Right "[\"algebra\",\"geometry\"]")
  , ("optional empty record remains present","root.people(\"alice\").empty = {}",Right "true")
  , ("absent empty record is null","root.people(\"bob\").empty = null",Right "true")
  , ("self reference resolves semantic identity","root.people(\"alice\").teacher = root.people(\"bob\")",Right "true")
  , ("terminal entity serializes key","root.people(\"alice\")",Right "{\"$entity\":\"Person\",\"key\":{\"name\":\"alice\"}}")
  , ("composite key names are order independent","root.sites(code:42,country:\"FR\").label",Right "\"Paris site\"")
  , ("filtered set lookup stays within that set","let q=select p from root.people as p where p.city=\"Lyon\"; q(\"alice\")",Right "null")
  , ("projection deduplicates values","select p.city from root.people as p",Right "[\"Lyon\",\"Paris\"]")
  , ("exist uniqueness counts projected values","exist!(select p.city from root.people as p where p.city=\"Paris\")",Right "true")
  , ("two distinct people are not unique","exist!(select p from root.people as p where p.city=\"Paris\")",Right "false")
  , ("select one deduplicates before checking","select! p.city from root.people as p where p.city=\"Paris\"",Right "\"Paris\"")
  , ("select one null is one value","select! null from root.people as p",Right "null")
  , ("select one zero fails","select! p from root.people as p where false",Left "CardinalityFailure")
  , ("select one several fails","select! p from root.people as p",Left "CardinalityFailure")
  , ("query values can be rebound and inspected","let people=select p from root.people as p where p.city=\"Paris\"; let alice=select! p from people as p where p.name=\"alice\"; {city:alice.city,uniqueCity:exist!(select p.city from people as p),uniquePerson:exist!(people)}",Right "{\"city\":\"Paris\",\"uniqueCity\":true,\"uniquePerson\":false}")
  , ("ordered where protects later demand","select t.city from root.people as p let t=p.teacher where not(t=null)",Right "[\"Paris\"]")
  , ("moving strict let before filter fails","select city from root.people as p let t=p.teacher let city=t.city where not(t=null)",Left "MissingValue")
  , ("unused query let is strict before false filter","select p.name from root.people as p let unused=p.teacher.name where false",Left "MissingValue")
  , ("unused top let is strict","let unused=root.people(\"nobody\").city; true",Left "MissingValue")
  , ("empty bindings do not evaluate later lets","select p.name from root.people as p where false let unused=root.people(\"nobody\").city",Right "[]")
  , ("existence cannot hide failing projection","exists(select p.teacher.name from root.people as p)",Left "MissingValue")
  , ("unique existence cannot hide failing projection","exist!(select p.teacher.name from root.people as p)",Left "MissingValue")
  , ("strict existential visits every body","exists p in root.people { p.name=\"alice\" or p.teacher.name=\"bob\" }",Left "MissingValue")
  , ("strict universal visits every body","every p in root.people { p.name=\"alice\" and p.teacher.name=\"bob\" }",Right "false")
  , ("strict universal cannot stop at a false witness","every p in root.people { p.name=\"claire\" and root.people(\"nobody\").name=\"x\" }",Left "MissingValue")
  , ("logic is lazy","false and root.people(\"nobody\").name=\"x\"",Right "false")
  , ("implication is lazy","false implies root.people(\"nobody\").name=\"x\"",Right "true")
  , ("or is lazy","true or root.people(\"nobody\").name=\"x\"",Right "true")
  , ("null Boolean is demanded","let p=root.people(\"nobody\"); let b=match root.people(\"alice\").role { Resident r => null; Visitor v => true; }; b and true",Left "MissingValue")
  , ("heterogeneous match","select match p.role { Resident r=>r.city; Visitor v=>{destination:v.destination}; } from root.people as p",Right "[\"Lyon\",\"Paris\",{\"destination\":\"Rome\"}]")
  , ("inactive match arm stays lazy","match root.people(\"alice\").role { Resident r=>r.city; Visitor v=>root.people(\"nobody\").city; }",Right "\"Paris\"")
  , ("fallback is selected","match root.people(\"bob\").role { Resident r=>r.city; _=>42; }",Right "42")
  , ("map call","root.people(\"alice\").schooling(track:\"science\",year:2026).label",Right "\"advanced\"")
  , ("missing map tuple","root.people(\"alice\").schooling(year:1900,track:\"science\")",Right "null")
  , ("entries retains complete argument tuple","select e.key.year as year,e.key.track as track,e.value.label as label from entries(root.people(\"alice\").schooling) as e",Right "[{\"year\":2026,\"track\":\"science\",\"label\":\"advanced\"}]")
  , ("nested correlated query","select p.name as name,count((select l from p.lessons as l)) as lessons from root.people as p where p.city=\"Paris\"",Right "[{\"name\":\"bob\",\"lessons\":1},{\"name\":\"alice\",\"lessons\":2}]")
  , ("empty every is true","every l in root.people(\"claire\").lessons {false}",Right "true")
  , ("empty exists is false","exists l in root.people(\"claire\").lessons {true}",Right "false")
  , ("record field order does not change equality","{a:1,b:true} = {b:true,a:1.0}",Right "true")
  , ("set equality ignores enumeration order","(select p.city from root.people as p) = (select q.city from root.people as q)",Right "true")
  , ("null membership","null in (select null from root.people as p)",Right "true")
  , ("entity membership","root.people(\"bob\") in root.people",Right "true")
  , ("union callees use the selected entity key signature","let range=match root.people(\"bob\").role { Resident r=>root.people; Visitor v=>root.lessons; }; range(\"algebra\")=root.lessons(\"algebra\")",Right "true")
  , ("scalar families remain distinct in a heterogeneous union","let x=match root.people(\"bob\").role { Resident r=>1; Visitor v=>\"1\"; }; x=1",Right "false")
  , ("Boolean and numeric set members remain distinct","count((select match p.role {Resident r=>1;Visitor v=>true;} from root.people as p))",Right "2")
  , ("exact decimal equality","0.123456789012345678901 = 123456789012345678901e-21",Right "true")
  , ("exact numeric storage lookup","root.sites(code:0.123456789012345678901,country:\"XX\").label",Right "\"exact\"")
  , ("timestamp offsets compare instants","timestamp(\"2026-10-17T12:00:00+02:00\") = timestamp(\"2026-10-17T10:00:00Z\")",Right "true")
  , ("shadowing is lexical","let p=\"outer\"; {inside:(select p.city from root.people as p),outside:p}",Right "{\"inside\":[\"Lyon\",\"Paris\"],\"outside\":\"outer\"}")
  ]

fixtureData :: P.PgSchema -> IO ()
fixtureData schema = do
  people <- table schema ("Person",[])
  lessons <- table schema ("Lesson",[])
  sites <- table schema ("Site",[])
  resident <- table schema ("Person",[R.Field "role",R.Branch "role" "Resident"])
  visitor <- table schema ("Person",[R.Field "role",R.Branch "role" "Visitor"])
  memberships <- table schema ("Person",[R.Field "lessons",R.Elements])
  schooling <- table schema ("Person",[R.Field "schooling",R.Entries])
  putStrLn "BEGIN;"
  putStrLn ("INSERT INTO " ++ people ++ " (id,name,city,__present_teacher,teacher,role_role,__present_empty) OVERRIDING SYSTEM VALUE VALUES (1,'alice','Paris',true,2,'Resident',true),(2,'bob','Paris',false,NULL,'Visitor',false),(3,'claire','Lyon',true,1,'Resident',false);")
  putStrLn ("INSERT INTO " ++ lessons ++ " (id,code,startsat) OVERRIDING SYSTEM VALUE VALUES (1,'algebra','2026-10-18T12:00:00Z'),(2,'geometry','2026-10-16T08:00:00Z');")
  putStrLn ("INSERT INTO " ++ sites ++ " (id,country,code,label) OVERRIDING SYSTEM VALUE VALUES (1,'FR',42,'Paris site'),(2,'XX',0.123456789012345678901,'exact');")
  putStrLn ("INSERT INTO " ++ resident ++ " (id,city) VALUES (1,'Paris'),(3,'Lyon');")
  putStrLn ("INSERT INTO " ++ visitor ++ " (id,destination) VALUES (2,'Rome');")
  putStrLn ("INSERT INTO " ++ memberships ++ " (id,value) VALUES (1,1),(1,2),(2,2);")
  putStrLn ("INSERT INTO " ++ schooling ++ " (id,schooling_entries_year,schooling_entries_track,label) VALUES (1,2026,'science','advanced');")
  putStrLn "COMMIT;"

table :: P.PgSchema -> P.SemanticOrigin -> IO String
table schema origin = do
  t <- right (P.tableForValue schema origin)
  assert "fixture uses an actual boundary" (P.pgValueOrigin t == origin)
  pure ("\"" ++ P.pgTableName t ++ "\"")

rolesData :: P.PgSchema -> IO ()
rolesData schema = do
  p <- table schema ("Person",[])
  l <- table schema ("Lesson",[])
  s <- table schema ("Person",[R.Field "role",R.Branch "role" "Student"])
  t <- table schema ("Person",[R.Field "role",R.Branch "role" "Teacher"])
  e <- table schema ("Person",[R.Field "role",R.Branch "role" "Student",R.Field "enrollments",R.Entries])
  tl <- table schema ("Person",[R.Field "role",R.Branch "role" "Teacher",R.Field "lessons",R.Elements])
  online <- table schema ("Lesson",[R.Field "delivery",R.Branch "delivery" "Online"])
  onsite <- table schema ("Lesson",[R.Field "delivery",R.Branch "delivery" "OnSite"])
  putStrLn "BEGIN;"
  putStrLn ("INSERT INTO " ++ p ++ " (id,name,role_role) OVERRIDING SYSTEM VALUE VALUES (1,'alice','Student'),(2,'bob','Teacher');")
  putStrLn ("INSERT INTO " ++ l ++ " (id,code,startsat,delivery_delivery) OVERRIDING SYSTEM VALUE VALUES (1,'A','2026-10-18T12:00:00Z','Online'),(2,'B','2026-10-19T12:00:00Z','OnSite');")
  putStrLn ("INSERT INTO " ++ s ++ " (id,programme,__present_adviser,adviser) VALUES (1,'science',true,2);")
  putStrLn ("INSERT INTO " ++ t ++ " (id,department) VALUES (2,'maths');")
  putStrLn ("INSERT INTO " ++ e ++ " (id,enrollments_entries_year,enrollments_entries_code,lesson) VALUES (1,2026,'one',1),(1,2026,'two',2);")
  putStrLn ("INSERT INTO " ++ tl ++ " (id,value) VALUES (2,1),(2,2);")
  putStrLn ("INSERT INTO " ++ online ++ " (id,platform,url) VALUES (1,'Teams','https://lesson.invalid');")
  putStrLn ("INSERT INTO " ++ onsite ++ " (id,campus,room) VALUES (2,'Paris','R1');")
  putStrLn "COMMIT;"

complexExpected :: String
complexExpected = "[{\"person\":{\"$entity\":\"Person\",\"key\":{\"name\":\"bob\"}},\"details\":{\"department\":\"maths\",\"supervisedStudents\":[{\"$entity\":\"Person\",\"key\":{\"name\":\"alice\"}}]}},{\"person\":{\"$entity\":\"Person\",\"key\":{\"name\":\"alice\"}},\"details\":{\"programme\":\"science\",\"adviser\":\"bob\",\"upcomingLessons\":[{\"year\":2026,\"lesson\":{\"$entity\":\"Lesson\",\"key\":{\"code\":\"A\"}},\"attendance\":{\"platform\":\"Teams\",\"url\":\"https://lesson.invalid\"}},{\"year\":2026,\"lesson\":{\"$entity\":\"Lesson\",\"key\":{\"code\":\"B\"}},\"attendance\":{\"campus\":\"Paris\",\"room\":\"R1\"}}]}}]"

-- Set transport order is deliberately not part of these source expectations.
publishedCases :: [(String,String)]
publishedCases =
  [ ("branch-cities.osql", "[\"Lyon\",\"Paris\"]")
  , ("composite-key.osql", "{\"$entity\":\"Site\",\"key\":{\"country\":\"FR\",\"code\":42}}")
  , ("grouped-cities.osql", "[{\"city\":\"Lyon\",\"count\":1,\"residents\":[{\"$entity\":\"Person\",\"key\":{\"name\":\"claire\"}}]},{\"city\":\"Paris\",\"count\":2,\"residents\":[{\"$entity\":\"Person\",\"key\":{\"name\":\"alice\"}},{\"$entity\":\"Person\",\"key\":{\"name\":\"bob\"}}]}]")
  , ("keyed-city.osql", "\"Paris\"")
  , ("map-entries.osql", "[{\"year\":2026,\"track\":\"science\",\"label\":\"advanced\"}]")
  , ("match-values.osql", "[{\"value\":\"Paris\"},{\"value\":\"Lyon\"},{\"value\":{\"destination\":\"Rome\"}}]")
  , ("nested-lessons.osql", "[]")
  , ("nullable-navigation.osql", "{\"city\":\"Paris\",\"teacher\":\"bob\",\"absent\":false}")
  , ("optional-alice.osql", "{\"$entity\":\"Person\",\"key\":{\"name\":\"alice\"}}")
  , ("quantified.osql", "[{\"$entity\":\"Person\",\"key\":{\"name\":\"alice\"}},{\"$entity\":\"Person\",\"key\":{\"name\":\"bob\"}}]")
  , ("query-bindings.osql", "{\"city\":\"Paris\",\"uniqueCity\":true,\"uniquePerson\":false}")
  , ("single-person.osql", "{\"$entity\":\"Person\",\"key\":{\"name\":\"alice\"}}")
  , ("teacher-cities.osql", "[\"Paris\"]")
  , ("unique-city.osql", "true")
  ]

structuredKeys :: IO ()
structuredKeys = do
  ontology <- right (O.parseModule "structured.ontology" (unlines
    [ "type User={ key name:string; };"
    , "type Tenant={ key code:string; };"
    , "type Empty={}; type Mode=alternative mode {Named:Empty;Coded:Empty;};"
    , "type Holder={ mode:Mode; codes:(code:string)=>string; names:(name:string)=>string; key identity:{person:Ref<User>;tenant:Ref<Tenant>;}; notes:(subject:Ref<User>,scope:{name:string;enabled:boolean;})=>{note:string;}; };"
    , "type Root={users:User[];tenants:Tenant[];holders:Holder[];};"
    ]) >>= checkOntology "Root")
  let source = "let user=only(root.users); let tenant=only(root.tenants); let holder=root.holders(identity:{tenant:tenant,person:user}); let lookup=match holder.mode { Named n=>holder.names; Coded c=>holder.codes; }; {lookup:lookup(\"x\"),holder:holder,note:holder.notes(scope:{enabled:true,name:\"x\"},subject:user).note,entries:count(entries(holder.notes)),sameMap:holder.notes=holder.notes}"
  checked <- check ontology source
  compiled <- right (Compile.compileProgram "structured" checked)
  let schema = Compile.compilationSchema compiled
  u <- table schema ("User",[])
  t <- table schema ("Tenant",[])
  h <- table schema ("Holder",[])
  n <- table schema ("Holder",[R.Field "notes",R.Entries])
  codes <- table schema ("Holder",[R.Field "codes",R.Entries])
  mode <- table schema ("Holder",[R.Field "mode",R.Branch "mode" "Coded"])
  putStrLn "CREATE SCHEMA osql_structured; SET search_path TO osql_structured;"
  putStr (Render.renderProgram (Physical.program schema))
  putStrLn "BEGIN;"
  putStrLn ("INSERT INTO " ++ u ++ " (id,name) OVERRIDING SYSTEM VALUE VALUES (7,'alice');")
  putStrLn ("INSERT INTO " ++ t ++ " (id,code) OVERRIDING SYSTEM VALUE VALUES (99,'one');")
  putStrLn ("INSERT INTO " ++ h ++ " (id,mode_mode,identity_person,identity_tenant) OVERRIDING SYSTEM VALUE VALUES (456,'Coded',7,99);")
  putStrLn ("INSERT INTO " ++ mode ++ " (id) VALUES (456);")
  putStrLn ("INSERT INTO " ++ codes ++ " (id,codes_entries_code,value) VALUES (456,'x','code-hit');")
  putStrLn ("INSERT INTO " ++ n ++ " (id,notes_entries_subject,notes_entries_scope_name,notes_entries_scope_enabled,note) VALUES (456,7,'x',true,'owned');")
  putStrLn "COMMIT;"
  putStr (Render.renderProgram (Compile.compilationSetup compiled))
  metadata "structured reference keys and map parameters" "{\"lookup\":\"code-hit\",\"holder\":{\"$entity\":\"Holder\",\"key\":{\"identity\":{\"person\":{\"$entity\":\"User\",\"key\":{\"name\":\"alice\"}},\"tenant\":{\"$entity\":\"Tenant\",\"key\":{\"code\":\"one\"}}}}},\"note\":\"owned\",\"entries\":1,\"sameMap\":true}"
  putStr (Render.renderQuery (Compile.compilationQuery compiled))

