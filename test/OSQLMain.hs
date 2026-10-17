module Main (main) where

import Control.Monad (forM_, unless)
import Data.Char (chr)
import Data.List (isInfixOf, sort)
import Data.List.NonEmpty (NonEmpty(..))
import OSQL.Parser
import OSQL.Syntax
import System.Directory (listDirectory)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath ((</>), takeExtension)

assert :: String -> Bool -> IO ()
assert description condition = unless condition (die ("FAIL: " ++ description))

accepted :: String -> IO Program
accepted source = case parseProgram "test.osql" source of
  Left problem -> die ("Unexpected rejection of " ++ show source ++ "\n" ++ renderParseError problem)
  Right result -> pure result

expression :: String -> IO Expr
expression source = case parseExpression "expression.osql" source of
  Left problem -> die (renderParseError problem)
  Right result -> pure result

rejected :: String -> IO ()
rejected source = case parseProgram "bad.osql" source of
  Left _ -> pure ()
  Right _ -> die ("Unexpected acceptance: " ++ source)

literal :: Literal -> Expr -> Bool
literal expected (Located _ (PostfixExpr (Located _ (Literal actual)) [])) = expected == actual
literal _ _ = False

variable :: Name -> Expr -> Bool
variable expected (Located _ (PostfixExpr (Located _ (Variable actual)) [])) = expected == actual
variable _ _ = False

selection :: Selection -> Expr -> Bool
selection expected (Located _ (Select query)) = querySelection query == expected
selection _ _ = False

main :: IO ()
main = do
  args <- getArgs
  directory <- case args of
    [] -> pure "docs/o-sql/examples"
    [path] -> pure path
    _ -> die "Usage: osql-parser-test [EXAMPLE_DIRECTORY]"
  files <- sort . filter ((== ".osql") . takeExtension) <$> listDirectory directory
  assert "published example corpus is present" (length files >= 15)
  forM_ files $ \file -> do
    source <- readFile (directory </> file)
    _ <- accepted source
    pure ()
  forM_ validSyntax $ \source -> accepted source >> pure ()
  forM_ invalidSyntax rejected
  cardinalityTests
  precedenceTests
  chainTests
  bindingTests
  lexicalTests
  diagnosticTests
  putStrLn ("OSQL parser: " ++ show (length files) ++ " complete examples, "
    ++ show (length validSyntax) ++ " syntax accepts, " ++ show (length invalidSyntax)
    ++ " syntax rejections, plus AST/cardinality/binding/lexical/location checks passed.")

cardinalityTests :: IO ()
cardinalityTests = do
  ordinary <- expression "select p from root.people as p"
  single <- expression "select! p from root.people as p"
  assert "select preserves set mode" (selection AllResults ordinary)
  assert "select! records single-result mode" (selection SingleResult single)
  forM_ ["exist!", "exists!"] $ \spelling -> do
    result <- expression (spelling ++ "(select p from root.people as p)")
    assert "unique existence records predicate, not single-result selection" $ case syntax result of
      PostfixExpr (Located _ (Exists UniqueResult (Located _ (Select query)))) [] -> querySelection query == AllResults
      _ -> False
  bound <- expression "exist!(people)"
  assert "unique existence accepts a stored query result" $ case syntax bound of
    PostfixExpr (Located _ (Exists UniqueResult value)) [] -> variable "people" value
    _ -> False
  result <- expression "exists(select p from root.people as p)"
  assert "ordinary existence remains distinct" $ case syntax result of
    PostfixExpr (Located _ (Exists NonEmptyResult _)) [] -> True
    _ -> False

precedenceTests :: IO ()
precedenceTests = do
  result <- expression "not a = b and c or d implies e implies f"
  assert "comparison, not, and, or, right-associative implication" $ case syntax result of
    Binary Implies
      (Located _ (Binary Or
        (Located _ (Binary And (Located _ (Not (Located _ (Binary Equal _ _)))) _)) _))
      (Located _ (Binary Implies _ _)) -> True
    _ -> False
  left <- expression "a and b and c"
  assert "and is left associative" $ case syntax left of
    Binary And (Located _ (Binary And _ _)) _ -> True
    _ -> False

chainTests :: IO ()
chainTests = do
  result <- expression "root.people(\"alice\")?.teacher?.name"
  assert "navigation is one flat chain of literal fields and applications" $ case syntax result of
    PostfixExpr (Located _ Root)
      [ Located _ (Field "people"), Located _ (Apply (Positional _))
      , Located _ (OptionalField "teacher"), Located _ (OptionalField "name") ] -> True
    _ -> False
  mixed <- expression "person.teacher?.teacher.name"
  assert "ordinary and optional fields remain distinct" $ case syntax mixed of
    PostfixExpr (Located _ (Variable "person"))
      [Located _ (Field "teacher"), Located _ (OptionalField "teacher"), Located _ (Field "name")] -> True
    _ -> False
  grouped <- expression "(a = b) and c"
  assert "Boolean grouping remains available" $ case syntax grouped of
    Binary And (Located _ (Group (Located _ (Binary Equal _ _)))) _ -> True
    _ -> False

bindingTests :: IO ()
bindingTests = do
  program <- accepted "let people = select p from root.people as p; let alice = select! p from people as p where p.name = \"alice\"; alice.city"
  assert "top-level query values are retained in ordered bindings" $ case program of
    Program [Located _ (Binding "people" allPeople), Located _ (Binding "alice" alice)] _ ->
      selection AllResults allPeople && selection SingleResult alice
    _ -> False
  nested <- expression "select lessons from root.people as p let lessons = (select lesson from p.lessons as lesson) where count(lessons) >= 2"
  assert "query-valued clause let precedes its where" $ case syntax nested of
    Select query -> case querySteps query of
      [Located _ (Let (Located _ (Binding "lessons" (Located _ (Group inner))))), Located _ (Where _)] -> selection AllResults inner
      _ -> False
    _ -> False
  duplicates <- expression "root.people(name: \"alice\", name: \"bob\")"
  assert "duplicate argument names survive for checking" $ case syntax duplicates of
    PostfixExpr _ [Located _ (Field _), Located _ (Apply (Named (("name", _) :| [("name", _)])))] -> True
    _ -> False
  match <- expression "match p.role { Student s => s.name; Teacher t => {department:t.department}; }"
  assert "heterogeneous arms and separate payload binders are retained" $ case syntax match of
    PostfixExpr (Located _ (Match _ (NamedArms
      (Located _ (CaseArm "Student" "s" _) :| [Located _ (CaseArm "Teacher" "t" record)]) Nothing))) [] ->
        case syntax record of
          PostfixExpr (Located _ (Record [("department", _)])) [] -> True
          _ -> False
    _ -> False
  fallback <- expression "match p.role { _ => null; }"
  assert "fallback-only syntax has no fake payload binder" $ case syntax fallback of
    PostfixExpr (Located _ (Match _ (DefaultOnly result))) [] -> literal NullLiteral result
    _ -> False

lexicalTests :: IO ()
lexicalTests = do
  number <- expression "-12.3400e+2"
  assert "decimal coefficients and scale remain exact" (literal (NumberLiteral (Decimal (-123400) (-2))) number)
  huge <- expression "1e999999999999999999999999999999"
  assert "exponent is not machine-bounded or evaluated" (literal (NumberLiteral (Decimal 1 999999999999999999999999999999)) huge)
  escaped <- expression "\"\\uD83D\\uDE00\\n\\/\""
  assert "JSON surrogate pair and escapes decode" (literal (TextLiteral [chr 0x1f600, '\n', '/']) escaped)
  unicode <- expression "élève२"
  assert "Unicode letter and decimal-digit identifier" (variable "élève२" unicode)
  timestamp <- expression "timestamp(\"not-yet-validated\")"
  assert "timestamp validation remains a checker responsibility" (literal (TimestampLiteral "not-yet-validated") timestamp)
  text <- expression "\"https://example.invalid/a//b\" // real comment\n"
  assert "comment markers inside strings remain text" (literal (TextLiteral "https://example.invalid/a//b") text)
  duplicates <- expression "{x:1,x:2}"
  assert "duplicate record fields are not overwritten" $ case syntax duplicates of
    PostfixExpr (Located _ (Record [("x", _), ("x", _)])) [] -> True
    _ -> False

diagnosticTests :: IO ()
diagnosticTests = do
  result <- case parseProgram "locations.osql" "// comment\n  root.people" of
    Left problem -> die (renderParseError problem)
    Right (Program [] value) -> pure value
    Right _ -> die "Unexpected definitions"
  assert "source file, line, column and offset retained"
    (spanFile (sourceSpan result) == "locations.osql"
      && spanStart (sourceSpan result) == Position 13 2 3
      && positionOffset (spanEnd (sourceSpan result)) == 24)
  case parseProgram "broken.osql" "select p\nfrom root.people as" of
    Right _ -> die "Expected malformed source diagnostic"
    Left problem -> assert "diagnostic includes filename and source line"
      ("broken.osql:2:" `isInfixOf` renderParseError problem && "root.people" `isInfixOf` renderParseError problem)

validSyntax :: [String]
validSyntax =
  [ "exist!(people)", "exists(people)", "exists!(root.people)", "exist!(1)", "root.people", "root.people(\"alice\")", "root.people(name: \"alice\")"
  , "root.sites(code:42,country:\"FR\")", "{}", "{match:true, null:null, _:false}"
  , "select p.match as where from root.people as p"
  , "select p as person, l as lesson from root.people as p, p.lessons as l"
  , "select {person:p,city:p.city} from root.people as p"
  , "let q = select p from root.people as p; q(\"alice\")"
  , "let q = select! p from root.people as p; q.city"
  , "select! p.city as city from root.people as p"
  , "exists (select p from root.people as p)"
  , "exist!(select p.city from root.people as p)"
  , "exists!(select p from root.people as p)"
  , "exists p in root.people { p.name = \"alice\" }"
  , "every p in root.people { exists l in p.lessons { l.startsAt < noon } }"
  , "match p.role { Student s => s.programme; _ => null; }"
  , "match p.role { Student s => select l from entries(s.enrollments) as l; Teacher t => select l from t.lessons as l; }"
  , "select match p.role { Student s => s.programme; Teacher t => t.department; } as details from root.people as p"
  , "select p from root.people as p let children = (select l from p.lessons as l) where count(children) >= 2"
  , "root.people(\"alice\")?.schooling(year:2026,track:\"science\")?.label"
  , "(select p from root.people as p)", "((a = b))", "not (a = b)"
  , "a <= b", "a >= b", "a < b", "a > b", "a in root.people"
  , "at(xs,-1)", "first(xs)", "only(root.people)", "count(root.people)"
  , "let _value = null; _value;", "selectable", "existsPerson", "existence"
  , "root.people(name:\"alice\",name:\"bob\")"
  , "select p as x,p as x from root.people as p"
  , "match p.role { Unknown x => null; _ => null; }"
  , "match p.role { Student s => s.name; Student t => t.name; _ => null; }"
  ]

invalidSyntax :: [String]
invalidSyntax =
  [ "", "let x = 1;", "root.people()", "root.people(\"alice\",\"bob\")"
  , "root.people(name:\"alice\",)", "root.people(\"alice\",name:\"bob\")"
  , "select p", "select p from root.people p", "select p.city,p.name from root.people as p"
  , "select p as p, from root.people as p", "select p from root.people as p where"
  , "select p from root.people as p let q = select l from p.lessons as l"
  , "a = b = c", "{x:1,}", "a.(field)", "a[\"city\"]", "a?.(field)", "a?.[field]"
  , "(a).city", "(a?.b).c", "(a?.b)(key)", "(select p from root.people as p)(\"alice\")"
  , "match p.role {}", "match p.role { Student s => s.name }"
  , "match p.role { Student => null; _ => null; }"
  , "match p.role { _ => null; Student s => s.name; }"
  , "match p.role { _ => null; _ => null; }"
  , "let _ = 1; null", "let null = 1; null", "let match = 1; null"
  , "select ! p from root.people as p", "exist ! (select p from root.people as p)"
  , "exist!(select p from root.people as p", "exist! p in root.people {true}"
  , "select p from root.people as p limit 1"
  , "+1", "01", "1.", "1e", "- 1", "1e+", "\"unterminated"
  , "\"\\x41\"", "\"\\u0000\"", "\"\\uD800\"", "\"\\uDC00\"", "\"\\uD800\\u0041\""
  , "/* no block comments */ root", "root.people?.", "not_a_keyword extra"
  ]

