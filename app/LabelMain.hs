module Main (main) where

import Control.Exception (IOException, catch)
import Control.Monad (when)
import Data.List (stripPrefix)
import System.Environment (getArgs)
import System.Exit (die, exitFailure)
import Text.Read (readMaybe)
import Ontology.Check (checkOntology)
import Ontology.Parser (parseModuleFile)
import qualified Ontology.Center.Graph as G
import qualified Ontology.Relational as R
import qualified Ontology.Postgres as P
import qualified Ontology.Projection as V
import qualified Ontology.Views as W
import qualified Ontology.Labels as L
import qualified Postgres.Read as Read
import qualified SQL.Render as Render

main :: IO ()
main = run `catch` ioFailure

ioFailure :: IOException -> IO ()
ioFailure e = failure [L.Diagnostic L.Error "io" "input file" (show e) Nothing]

failure :: [L.Diagnostic] -> IO a
failure ds = putStrLn (L.reportJSON (L.LabelReport [] ds)) >> exitFailure

right :: Either String a -> IO a
right = either (\message -> failure [L.Diagnostic L.Error "compile" "input" message Nothing]) pure

checked :: Either [L.Diagnostic] a -> IO a
checked = either failure pure

run :: IO ()
run = do
  args <- getArgs
  case args of
    file:root:pop:depthText:command:rest -> do
      depth <- maybe (die "DEPTH must be a nonnegative integer") pure (readMaybe depthText)
      when (depth < 0) (die "DEPTH must be nonnegative")
      (catalogFile, centerArgs) <- case (command, rest) of
        ("check", catalog:steps) -> pure (Just catalog,steps)
        ("sql", catalog:steps) -> pure (Just catalog,steps)
        ("requirements", steps) -> pure (Nothing,steps)
        ("template", steps) -> pure (Nothing,steps)
        _ -> die usage
      steps <- mapM centerStep centerArgs
      parsed <- parseModuleFile file
      ontology <- right (parsed >>= checkOntology root)
      graph <- right (G.world root ontology)
      view <- right (W.prepareView graph (W.ViewSource "view" pop steps (V.forwardValue depth)))
      required <- checked (L.requirementsFor graph [view])
      case command of
        "template" -> putStr (L.exportTemplate required)
        "requirements" -> putStrLn (L.reportJSON (L.checkLabels ontology graph [view] (L.Catalog "en" [])))
        _ -> do
          catalog <- case catalogFile of
            Just "-" -> pure Nothing
            Just path -> Just <$> (checked =<< L.parseLabelsFile path)
            Nothing -> die usage
          case command of
            "check" -> case catalog of
              Nothing -> do
                _ <- checked (L.prepareLabeling ontology graph [view] Nothing)
                putStrLn (L.reportJSON (L.LabelReport [] []))
              Just source -> do
                let report = L.checkLabels ontology graph [view] source
                putStrLn (L.reportJSON report)
                when (any ((== L.Error) . L.diagnosticSeverity) (L.labelDiagnostics report)) exitFailure
            "sql" -> do
              labels <- checked (L.prepareLabeling ontology graph [view] catalog)
              meaning <- right (R.relational root ontology)
              schema <- right (P.postgres meaning)
              query <- right (Read.compilePreparedWith labels meaning schema view)
              putStr (Render.renderPrepared "view" (Read.parameterSqlTypes view) query)
            _ -> die usage
    _ -> die usage

centerStep :: String -> IO W.CenterStep
centerStep "items" = pure W.CenterElements
centerStep "entries" = pure W.CenterEntries
centerStep "tag" = pure W.CenterTag
centerStep s
  | Just field <- stripPrefix "field:" s = pure (W.CenterField field)
  | Just argument <- stripPrefix "arg:" s = pure (W.CenterArgument argument)
  | Just index <- stripPrefix "case:" s = case readMaybe index of
      Just n | n >= 0 -> pure (W.CenterBranch n)
      _ -> die "case:N requires a nonnegative branch index"
  | otherwise = pure (W.CenterField s)

usage :: String
usage = unlines
  [ "ontology-labels ONTOLOGY ROOT POPULATION DEPTH COMMAND [CATALOG] [CENTER ...]"
  , "Commands: template | requirements | check CATALOG | sql CATALOG"
  , "Use '-' instead of CATALOG for the technical interpretation."
  , "Center steps: field:name (or name), items, entries, arg:name, case:N, tag."
  , "requirements/check emit JSON. An incomplete check exits nonzero."
  , "Syntax errors and IO errors are fatal JSON diagnostics; no partial catalog is executed." ]

