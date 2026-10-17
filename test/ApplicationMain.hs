{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM, forM_)
import Data.List (isPrefixOf, isSuffixOf)
import qualified Data.Aeson as A
import Data.Aeson ((.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Map.Strict as M
import System.Environment (getArgs)
import System.Exit (die)
import Ontology.Parser (parseModuleFile)
import Ontology.Check (checkOntology)
import Ontology.Center.Lazy (center)
import qualified Ontology.Center.Graph as G
import qualified Ontology.Relational as R
import qualified Ontology.Postgres as P
import qualified Ontology.Projection as V
import qualified Ontology.Views as W
import qualified Ontology.Syntax as O
import qualified Ontology.Labels as L
import qualified Postgres.Read as Read
import Application.Compiler
import Application.Data
import Application.Presentation
import Application.JSX
import Application.Files
import Application.TypeScript
import Application.Endpoint (endpointQuery)

right :: Either String a -> IO a
right = either die pure
checked :: Either [L.Diagnostic] a -> IO a
checked = either (die . L.renderReport . L.LabelReport []) pure
assert :: Bool -> String -> IO ()
assert condition message = unless condition (die message)

only :: Int -> [G.Primitive] -> V.Projector
only depth fields = (V.forwardValue depth) { V.edgeSelection = V.OnlyEdges (map V.Through fields) }

sources :: [W.ViewSource]
sources =
  [ view "all" [] (V.forwardValue 6)
  , view "summary" [] (only 1 (map G.Field ["code","name","status","other","rank","flag","optional"]))
  , view "manager" [field "manager"] (V.forwardValue 0)
  , view "manager_full" [field "manager"]
      ((only 2 [G.Reference "Person",G.Field "code",G.Field "name"]) { V.references = V.FollowReferences })
  , view "pair" [field "pair"] (V.forwardValue 0)
  , view "first" [field "first"] (V.forwardValue 2)
  , view "second" [field "second"] (V.forwardValue 2)
  , view "tags" [] (only 3 [G.Field "tags",G.Elements R.DistinctWhole])
  , view "tag_values" [field "tags"] (V.forwardValue 3)
  , view "work" [field "work"] (V.forwardValue 4)
  , view "score" [field "work",W.CenterEntries,field "score"] (V.forwardValue 0)
  , view "contact" [field "contacts",W.CenterElements] (V.forwardValue 2)
  , view "choice" [field "choice"] (V.forwardValue 4)
  , view "active" [field "choice",W.CenterBranch 0] (V.forwardValue 3)
  , view "tag" [field "choice",W.CenterTag] (V.forwardValue 0)
  , view "name_context" [field "name"]
      ((V.neighborhood 2) { V.edgeSelection = V.OnlyEdges (map V.Through [G.Field "name",G.Field "code"]) })
  , view "cutoff" [] (V.forwardValue 0)
  , view "branch_only" [field "choice"] (only 3 [G.Variant "state" "Active",G.Field "note"])
  ]
  where view name = W.ViewSource name "Person"; field = W.CenterField

inverseView :: G.World -> IO W.PreparedView
inverseView graph = do
  let target = G.population "Person"
      source = G.within target [R.Field "manager"]
  edge <- case [e | e <- G.outgoingAt graph source, G.edgeTarget e == target] of
    [e] -> pure e
    _ -> die "Expected manager reference"
  route <- right (G.ownerRoute graph source >>= \r -> G.compose r (G.forward edge))
  base <- right (W.prepareView graph (W.ViewSource "inverse_manager" "Person" [] (V.forwardValue 0)))
  child <- right (center graph target >>= V.project (only 1 [G.Field "code",G.Field "name"]))
  pure base { W.preparedProjection = (W.preparedProjection base)
    { V.projectedExpansion = V.Expanded [] [V.Followed (G.inverse route) child] } }

arguments :: [[String]]
arguments =
  [ ["P1"],["P2"],["missing"],["P1"],["P2"],["P1"],["P1"],["P1"],["P1"]
  , ["P1"],["P2"],["P1"],["P1"],["P1","2026"],["P1","1999"]
  , ["P1","active","a@x"],["P1"],["P2"],["P1"],["P2"],["P1"],["P1"],["P1"],["P2"] ]

oracle :: FilePath -> IO [(String,A.Value)]
oracle file = do
  input <- B.readFile file
  values <- mapM (right . A.eitherDecodeStrict' . T.encodeUtf8)
    (filter (not . T.null) (T.lines (T.decodeUtf8 (B.toStrict input))))
  pairs values
  where
    pairs [] = pure []
    pairs (A.Object metadata:actual:rest) = do
      name <- case KM.lookup "case" metadata of Just (A.String value) -> pure (T.unpack value); _ -> die "Missing oracle case"
      expected <- maybe (die "Missing oracle expected value") pure (KM.lookup "expected" metadata)
      assert (actual == expected) "Legacy PostgreSQL oracle failed"
      tailPairs <- pairs rest
      pure (if "raw_" `isPrefixOf` name && " prepared" `isSuffixOf` name
        then (take (length name - 13) (drop 4 name),actual):tailPairs else tailPairs)
    pairs _ = die "Incomplete PostgreSQL oracle pairs"

slug :: String -> String
slug = map (\c -> if c == '_' then '-' else c)
jsonText :: A.ToJSON a => a -> String
jsonText = T.unpack . T.decodeUtf8 . B.toStrict . A.encode

main :: IO ()
main = do
  args <- getArgs
  (output,oracleFile) <- case args of [a,b] -> pure (a,b); _ -> die "application-tests OUTPUT ORACLE_JSONL"
  parsed <- parseModuleFile "test/fixtures/labels.ontology"
  ontology <- right (parsed >>= checkOntology "Root")
  meaning <- right (R.relational "Root" ontology)
  schema <- right (P.postgres meaning)
  graph <- right (G.world "Root" ontology)
  base <- mapM (right . W.prepareView graph) sources
  backwards <- inverseView graph
  let views = base ++ [backwards]
      specs = [PageSpec (slug (W.preparedName v)) ("View: " ++ W.preparedName v) v | v <- views]
  catalog <- L.parseLabelsFile "test/fixtures/labels.en.label" >>= checked
  labels <- checked (L.prepareLabeling ontology graph views (Just catalog))
  scaffold <- readScaffold "templates/app"
  manifest <- right (compileApplication scaffold graph meaning schema labels specs)
  again <- right (compileApplication scaffold graph meaning schema labels specs)
  assert (manifest == again) "Application compilation is not deterministic"
  pages <- mapM (right . compilePage graph meaning schema labels) specs
  let byView = M.fromList [(W.preparedName (pageView (specification p)),p) | p <- pages]
      failed value = case value of Left _ -> True; Right _ -> False
  assert (failed (files [("../escape","x")])) "Unsafe output path accepted"
  assert (failed (files [("A.ts","x"),("a.ts","y")])) "Case-insensitive path collision accepted"
  assert (failed (compileApplication scaffold graph meaning schema labels (take 1 specs ++ specs))) "Duplicate page names accepted"
  forM_ pages $ \page -> do
    query <- right (Read.compilePrepared meaning schema (pageView (specification page)))
    assert (query == endpointQuery (pageEndpoint page)) "Endpoint changed the technical selector"
  let repeatedLabels = labels { L.nameOf = const (Right "Same caption") }
  _ <- right (compilePage graph meaning schema repeatedLabels (head specs))
  rows <- oracle oracleFile
  assert (length rows == length arguments) "Unexpected legacy oracle case count"
  checks <- forM (zip rows arguments ++
      [(("branch_only",A.object ["Active" .= A.object ["note" .= ("Hello" :: String)]]),["P1"])
      ,(("branch_only",A.object []),["P2"])]) $ \((viewName,value),values) -> do
    page <- maybe (die ("Unknown view " ++ viewName)) pure (M.lookup viewName byView)
    let params = W.preparedParameters (pageView (specification page))
    assert (length params == length values) "Parameter count mismatch"
    observations <- right (interpret (pagePresentation page) value)
    pure (A.object ["page" .= pageName (specification page)
      ,"parameters" .= M.fromList (zip (map W.parameterName params) values)
      ,"expected" .= value,"observations" .= observations])
  let hostile = "Caf\233 <script>globalThis.pwned = true</script> & \"quotes\""
      nested = ArrayData (ArrayData (ScalarData (SemanticScalar (G.population "Text") (R.ScalarAtom O.TString))))
  nestedPresentation <- right (presentation L.technical nested)
  let nestedValue = A.toJSON ([[hostile,"second"],[],["third"]] :: [[String]])
  nestedObservations <- right (interpret nestedPresentation nestedValue)
  extras <- right (files
    [ ("test-cases.json", jsonText checks)
    , ("shared/nested-test.ts", contractModule nested)
    , ("client/views/nested-test.tsx", "import type { ViewData } from '../../shared/nested-test.js';\nexport function View({data}: {data: ViewData}) { return (" ++ renderJSX (lower nestedPresentation) ++ "); }\n")
    , ("client/views/hostile-test.tsx", "export function View() { return (" ++ renderJSX (Element Heading [Observation "caption"] [TextNode hostile]) ++ "); }\n")
    , ("nested-test.json", jsonText (A.object ["value" .= nestedValue,"observations" .= nestedObservations,"caption" .= hostile]))
    ])
  combined <- right (combine [manifest,extras])
  writeFresh output combined
  putStrLn ("Verified pure application laws; generated " ++ show (length pages) ++ " pages and " ++ show (length checks) ++ " data cases")

