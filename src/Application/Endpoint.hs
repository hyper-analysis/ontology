module Application.Endpoint
  ( Endpoint(..), endpoint, endpointModule, validName
  ) where

import Control.Monad (unless)
import Data.Char (isAsciiLower, isDigit)
import Data.List (intercalate)
import Application.JSX (jsString, literalJS)
import Ontology.Views (PreparedView(..), Parameter(..))
import qualified Ontology.Relational as R
import qualified Ontology.Postgres as P
import qualified Ontology.Syntax as O
import qualified Postgres.Read as Read
import qualified SQL.Syntax as SQL
import qualified SQL.Render as Render

data Endpoint = Endpoint
  { endpointName :: String
  , endpointParameters :: [Parameter]
  , endpointQuery :: SQL.Query
  } deriving (Eq, Show)

-- One name supplies a filename-safe and route-safe API/page identity. It is
-- unrelated to the semantic identity of the object supplied as parameters.
validName :: String -> Bool
validName [] = False
validName (x:xs) = isAsciiLower x && length xs < 80
  && all (\c -> isAsciiLower c || isDigit c || c == '-') xs

endpoint :: String -> R.Relational -> P.PgSchema -> PreparedView -> Either String Endpoint
endpoint name meaning schema view = do
  unless (validName name) (Left "Endpoint name must match [a-z][a-z0-9-]* (at most 80 characters)")
  query <- Read.compilePrepared meaning schema view
  pure (Endpoint name (preparedParameters view) query)

parameterSpec :: Parameter -> Either String String
parameterSpec parameter = do
  kind <- atomKind (parameterAtom parameter)
  pure ("{ name: " ++ jsString (parameterName parameter) ++ ", kind: " ++ jsString kind
    ++ ", allowed: " ++ domain (parameterAtom parameter) ++ " }")
  where
    atomKind (R.ScalarAtom O.TString) = Right "string"
    atomKind (R.ScalarAtom O.TTimestamp) = Right "timestamp"
    atomKind (R.ScalarAtom O.TNumber) = Right "number"
    atomKind (R.ScalarAtom O.TBoolean) = Right "boolean"
    atomKind (R.LiteralAtom literal) = Right (literalKind literal)
    atomKind (R.EnumAtom (literal:_)) = Right (literalKind literal)
    atomKind _ = Left "Endpoint parameter must have a finite scalar representation"
    literalKind O.TextLiteral{} = "string"
    literalKind O.NumberLiteral{} = "number"
    literalKind O.BooleanLiteral{} = "boolean"
    domain (R.LiteralAtom value) = "[" ++ literalJS value ++ "]"
    domain (R.EnumAtom values) = "[" ++ intercalate "," (map literalJS values) ++ "]"
    domain _ = "null"

endpointModule :: Endpoint -> Either String String
endpointModule description = do
  parameters <- mapM parameterSpec (endpointParameters description)
  let name = endpointName description
      sql = Render.renderQuery (SQL.ValueQuery (SQL.JsonOne (endpointQuery description)))
  pure (unlines
    [ "import type { Express } from 'express';"
    , "import type { Pool } from 'pg';"
    , "import { registerRead } from '../runtime.js';"
    , "import { isViewData } from '../../shared/" ++ name ++ ".js';"
    , "export const specification = {"
    , "  name: " ++ jsString name ++ ","
    , "  parameters: [" ++ intercalate "," parameters ++ "],"
    , "  sql: " ++ jsString sql
    , "} as const;"
    , "export function install(app: Express, pool: Pool): void {"
    , "  registerRead(app, pool, specification, isViewData);"
    , "}"
    ])

