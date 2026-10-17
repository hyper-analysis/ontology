module Application.Compiler
  ( PageSpec(..), Page(..), compilePage, compileApplication, pageFiles
  ) where

import Control.Monad (unless)
import Data.Char (isSpace)
import Data.List (intercalate, nub)
import Application.Data
import Application.Presentation
import Application.JSX
import Application.TypeScript
import Application.Endpoint
import Application.Files
import Ontology.Center.Graph (World)
import Ontology.Labels.Types (Labeling)
import Ontology.Views (PreparedView)
import qualified Ontology.Relational as R
import qualified Ontology.Postgres as P
import qualified Postgres.Physical as Physical
import qualified SQL.Render as SQL
import qualified Postgres.Read as Read

data PageSpec = PageSpec
  { pageName :: String
  , pageTitle :: String
  , pageView :: PreparedView
  } deriving (Eq, Show)
data Page = Page
  { specification :: PageSpec
  , pageCorrespondence :: PageData
  , pagePresentation :: Presentation
  , pageJSX :: JSX
  , pageEndpoint :: Endpoint
  } deriving (Eq, Show)

compilePage :: World -> R.Relational -> P.PgSchema -> Labeling -> PageSpec -> Either String Page
compilePage graph meaning schema labels spec = do
  unless (not (all isSpace (pageTitle spec))) (Left "Page title must not be blank")
  api <- endpoint (pageName spec) meaning schema (pageView spec)
  correspondence <- pageData graph (pageView spec)
  body <- presentation labels correspondence
  let jsx = Element Main []
        [Element Heading [] [TextNode (pageTitle spec)], lower body]
  pure (Page spec correspondence body jsx api)

-- All associations are constructed from the same PreparedView, never by
-- comparing two accidentally equal JSON shapes or pairing names heuristically.
compileApplication :: Files -> World -> R.Relational -> P.PgSchema -> Labeling -> [PageSpec] -> Either String Files
compileApplication scaffold graph meaning schema labels specs = do
  unless (not (null specs)) (Left "An application requires at least one page")
  unless (length names == length (nub names)) (Left "Duplicate page/endpoint name")
  pages <- mapM (compilePage graph meaning schema labels) specs
  outputs <- mapM pageFiles pages
  roots <- files
    [ ("server/main.ts", serverMain specs)
    , ("client/main.tsx", clientMain specs)
    , ("sql/schema.sql", SQL.renderProgram (Physical.program schema))
    , ("views.txt", unlines ["/views/" ++ pageName s ++ " -> /api/views/" ++ pageName s
        ++ "\n" ++ show (pageView s) ++ "\n" | s <- specs]) ]
  combine (scaffold : roots : outputs)
  where names = map pageName specs

pageFiles :: Page -> Either String Files
pageFiles page = do
  apiSource <- endpointModule (pageEndpoint page)
  let spec = specification page
      name = pageName spec
  files
    [ ("shared/" ++ name ++ ".ts", contractModule (pageCorrespondence page))
    , ("client/views/" ++ name ++ ".tsx", unlines
        [ "import type { ViewData } from '../../shared/" ++ name ++ ".js';"
        , "export function View({ data }: { readonly data: ViewData }) {"
        , "  return (" ++ renderJSX (pageJSX page) ++ ");"
        , "}" ])
    , ("client/pages/" ++ name ++ ".tsx", unlines
        [ "import { ReadPage } from '../page-runtime.js';"
        , "import { View } from '../views/" ++ name ++ ".js';"
        , "import { isViewData } from '../../shared/" ++ name ++ ".js';"
        , "export function Page() {"
        , "  return <ReadPage endpoint={" ++ jsString ("/api/views/" ++ name)
            ++ "} View={View} accept={isViewData} />;"
        , "}" ])
    , ("server/endpoints/" ++ name ++ ".ts", apiSource)
    , ("sql/" ++ name ++ ".sql", SQL.renderPrepared name
        (Read.parameterSqlTypes (pageView spec)) (endpointQuery (pageEndpoint page)))
    , ("ir/" ++ name ++ ".txt", unlines
        [ "PAGE DATA", show (pageCorrespondence page)
        , "PRESENTATION", show (pagePresentation page)
        , "JSX", show (pageJSX page)
        , "ENDPOINT", show (pageEndpoint page) ])
    ]

serverMain :: [PageSpec] -> String
serverMain specs = unlines
  (["import { serve } from './runtime.js';"]
    ++ ["import { install as install" ++ show i ++ " } from './endpoints/" ++ pageName spec ++ ".js';"
       | (i,spec) <- zip [0 :: Int ..] specs]
    ++ ["serve([" ++ intercalate "," ["install" ++ show i | (i,_) <- zip [0 :: Int ..] specs]
      ++ "], [" ++ intercalate "," [jsString ("/views/" ++ pageName spec) | spec <- specs] ++ "]);"])

clientMain :: [PageSpec] -> String
clientMain specs = unlines
  (["import { createRoot } from 'react-dom/client';"]
    ++ ["import { Page as Page" ++ show i ++ " } from './pages/" ++ pageName spec ++ ".js';"
       | (i,spec) <- zip [0 :: Int ..] specs]
    ++ [ "function Route() {", "  switch (window.location.pathname) {" ]
    ++ ["    case " ++ jsString ("/views/" ++ pageName spec) ++ ": return <Page" ++ show i ++ " />;"
       | (i,spec) <- zip [0 :: Int ..] specs]
    ++ [ "    default: return <main><h1>View not selected</h1><p>Open a generated view URL with its identifying parameters.</p></main>;"
       , "  }", "}", "const root = document.getElementById('root');"
       , "if (!root) throw new Error('Missing root element');"
       , "createRoot(root).render(<Route />);" ])

