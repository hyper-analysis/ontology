module Main (main) where

import Ontology.Check (checkOntology, ontologySummary)
import Ontology.Parser (parseModuleFile)
import Ontology.Postgres (localProgram, postgres, postgresSummary)
import Ontology.Relational (relational, relationalSummary)
import SQL.Render (renderProgram)
import Postgres.Physical (program)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  (file, rootName, mode) <- case args of
    [path, root] -> pure (path, root, "ontology")
    [path, root, "--relational"] -> pure (path, root, "relational")
    [path, root, "--postgres"] -> pure (path, root, "postgres")
    [path, root, "--sql-local"] -> pure (path, root, "sql-local")
    [path, root, "--sql"] -> pure (path, root, "sql")
    _ ->
      die
        "Usage: ontology-check FILE ROOT [--relational|--postgres|--sql-local|--sql]"

  parsed <- parseModuleFile file
  syntax <- either die pure parsed
  ontology <- either die pure (checkOntology rootName syntax)

  case mode of
    "ontology" ->
      putStr (ontologySummary ontology)

    "relational" -> do
      meaning <- either die pure (relational rootName ontology)
      putStr (relationalSummary meaning)

    "postgres" -> do
      meaning <- either die pure (relational rootName ontology)
      pg <- either die pure (postgres meaning)
      putStr (postgresSummary pg)

    "sql-local" -> do
      meaning <- either die pure (relational rootName ontology)
      pg <- either die pure (postgres meaning)
      putStr (renderProgram (localProgram pg))

    "sql" -> do
      meaning <- either die pure (relational rootName ontology)
      pg <- either die pure (postgres meaning)
      putStr (renderProgram (program pg))

    _ ->
      die "internal mode error"

