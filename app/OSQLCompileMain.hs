module Main (main) where

import qualified Ontology.Parser as Ontology
import Ontology.Check (checkOntology)
import OSQL.Parser (parseProgram, renderParseError)
import OSQL.Check (checkProgram, resultType, renderDiagnostic)
import OSQL.Type (prettyType)
import OSQL.Compile (compileProgram, renderCompilation, LoweringError(..))
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  (ontologyFile,root,queryFile,namespace) <- case args of
    [o,r,q] -> pure (o,r,q,"osql_query")
    [o,r,q,n] -> pure (o,r,q,n)
    _ -> die "Usage: osql-compile ONTOLOGY ROOT QUERY [FUNCTION_NAMESPACE]"
  ontologySource <- readFile ontologyFile
  ontology <- either die pure (Ontology.parseModule ontologyFile ontologySource >>= checkOntology root)
  source <- readFile queryFile
  parsed <- either (die . renderParseError) pure (parseProgram queryFile source)
  checked <- either (die . renderDiagnostic) pure (checkProgram root ontology parsed)
  compiled <- either (\(LoweringError code message) -> die (code ++ ": " ++ message)) pure (compileProgram namespace checked)
  hPutStrLn stderr ("Result: " ++ prettyType (resultType checked))
  putStr (renderCompilation compiled)

