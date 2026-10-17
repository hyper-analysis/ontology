module Main (main) where

import Control.Exception (IOException, catch)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Ontology.Parser (parseModuleFile)
import Ontology.Check (checkOntology)
import qualified Ontology.Center.Graph as G
import qualified Ontology.Relational as R
import qualified Ontology.Postgres as P
import qualified Ontology.Labels as L
import Application.Input
import Application.Compiler
import Application.Files

main :: IO ()
main = run `catch` ioFailure

ioFailure :: IOException -> IO ()
ioFailure exception = failure "io" (show exception)

failure :: String -> String -> IO a
failure code message = do
  hPutStrLn stderr (L.reportJSON (L.LabelReport []
    [L.Diagnostic L.Error code "application" message Nothing]))
  exitFailure

right :: Either String a -> IO a
right = either (failure "compile") pure

checked :: Either [L.Diagnostic] a -> IO a
checked = either (\diagnostics -> hPutStrLn stderr (L.reportJSON (L.LabelReport [] diagnostics)) >> exitFailure) pure

run :: IO ()
run = do
  args <- getArgs
  case args of
    [ontologyFile,root,labelFile,applicationFile,destination] ->
      compile ontologyFile root labelFile applicationFile destination "templates/app"
    [ontologyFile,root,labelFile,applicationFile,destination,templates] ->
      compile ontologyFile root labelFile applicationFile destination templates
    _ -> failure "usage" "ontology-app ONTOLOGY ROOT LABELS_OR_DASH APP_JSON NEW_DIRECTORY [TEMPLATES]"
  where
    compile ontologyFile root labelFile applicationFile destination templates = do
      parsed <- parseModuleFile ontologyFile
      ontology <- right (parsed >>= checkOntology root)
      meaning <- right (R.relational root ontology)
      schema <- right (P.postgres meaning)
      graph <- right (G.world root ontology)
      input <- readFile applicationFile >>= right . parseApplication
      pages <- right (preparePages graph input)
      catalog <- if labelFile == "-" then pure Nothing
        else Just <$> (L.parseLabelsFile labelFile >>= checked)
      labels <- checked (L.prepareLabeling ontology graph (map pageView pages) catalog)
      scaffold <- readScaffold templates
      output <- right (compileApplication scaffold graph meaning schema labels pages)
      writeFresh destination output
      putStrLn ("Generated " ++ show (length (fileList output)) ++ " files in " ++ destination)

