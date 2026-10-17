module Main (main) where

import Control.Exception (IOException, catch)
import GHC.IO.Encoding (setFileSystemEncoding, setLocaleEncoding, utf8)
import qualified Ontology.Parser as Ontology
import Ontology.Check (checkOntology, ontologySummary)
import Ontology.Relational (relational, relationalSummary)
import Ontology.Postgres (postgres)
import qualified OSQL.Parser as Query
import qualified OSQL.Check as Query
import qualified OSQL.Compile as Query
import OSQL.Type (prettyType)
import Postgres.Physical (program)
import SQL.Render (renderProgram)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hPutStrLn, hSetEncoding, stdin, stdout, stderr)

usage :: String
usage = unlines
  [ "Ontology 0.1.0 — semantic data modeling and PostgreSQL compilation"
  , ""
  , "Usage: ontology COMMAND FILE [QUERY] --root TYPE [--namespace NAME]"
  , "  check    Validate an ontology"
  , "  compile  Emit a complete PostgreSQL schema on stdout"
  , "  inspect  Show the relational interpretation"
  , "  query    Compile an O-SQL file into PostgreSQL read functions and a result query"
  , ""
  , "query emits SQL; execute it separately with psql."
  , "--namespace is available only for query (default: osql_query)."
  , "ontology --help | --version"
  ]

data Options = Options [String] (Maybe String) (Maybe String)

options :: [String] -> Options -> Either String Options
options [] result = Right result
options ("--root":name:rest) (Options files Nothing ns) =
  options rest (Options files (Just name) ns)
options ("--namespace":name:rest) (Options files root Nothing) =
  options rest (Options files root (Just name))
options (arg:rest) (Options files root ns)
  | take 1 arg == "-" = Left ("Invalid or repeated option: " ++ arg)
  | otherwise = options rest (Options (files ++ [arg]) root ns)

main :: IO ()
main = do
  setLocaleEncoding utf8
  setFileSystemEncoding utf8
  mapM_ (`hSetEncoding` utf8) [stdin, stdout, stderr]
  run `catch` ioFailure
  where ioFailure :: IOException -> IO ()
        ioFailure = die . show

run :: IO ()
run = do
  args <- getArgs
  case args of
    ["--help"] -> putStr usage
    ["--version"] -> putStrLn "ontology 0.1.0"
    [_, "--help"] -> putStr usage
    command:rest | command `elem` ["check", "compile", "inspect", "query"] -> do
      Options files root ns <- either die pure (options rest (Options [] Nothing Nothing))
      rootName <- maybe (die "Missing --root TYPE") pure root
      file <- case (command, files, ns) of
        ("query", [path, _], _) -> pure path
        (_, [path], Nothing) | command /= "query" -> pure path
        _ -> die usage
      parsed <- Ontology.parseModuleFile file
      ontology <- either die pure (parsed >>= checkOntology rootName)
      case (command, files) of
        ("check", _) -> putStr (ontologySummary ontology)
        ("inspect", _) -> either die (putStr . relationalSummary) (relational rootName ontology)
        ("compile", _) -> either die (putStr . renderProgram . program)
          (relational rootName ontology >>= postgres)
        ("query", [_, queryFile]) -> do
          source <- readFile queryFile
          syntax <- either (die . Query.renderParseError) pure (Query.parseProgram queryFile source)
          checked <- either (die . Query.renderDiagnostic) pure (Query.checkProgram rootName ontology syntax)
          let namespace = maybe "osql_query" id ns
          compiled <- either (\(Query.LoweringError code message) -> die (code ++ ": " ++ message)) pure
            (Query.compileProgram namespace checked)
          hPutStrLn stderr ("Result: " ++ prettyType (Query.resultType checked))
          putStr (Query.renderCompilation compiled)
        _ -> die usage
    _ -> die usage
