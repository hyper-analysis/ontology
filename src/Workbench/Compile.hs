{-# LANGUAGE OverloadedStrings #-}
module Workbench.Compile (compileOntology, compileSelector) where

import Control.Applicative ((<|>))
import Data.Aeson (Value, object, toJSON, (.=))
import Data.List (find, nubBy, intercalate)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe, listToMaybe)
import qualified Ontology.Syntax as O
import Ontology.Parser (parseModuleLocated, SourceSpan(..), SourceLocation(..))
import Ontology.Check (checkOntology)
import qualified Ontology.Relational as R
import qualified Ontology.Postgres as P
import qualified Postgres.Physical as Physical
import qualified OSQL.Parser as QP
import qualified OSQL.Check as QC
import qualified OSQL.Compile as Q
import qualified OSQL.Type as QT
import qualified SQL.Render as SQL
import qualified SQL.Syntax as S

spanJSON :: Maybe SourceSpan -> Value
spanJSON = maybe (toJSON (Nothing :: Maybe Int)) (\s -> object ["start" .= spanStart s, "end" .= spanEnd s])

-- Follow the source AST, including named aliases, rather than searching text
-- for a field spelling. Repeated field names and comments remain unambiguous.
sourceFor :: O.Module -> [SourceLocation] -> String -> R.Path -> Maybe SourceSpan
sourceFor syntax locations population path = definition [] population (mapMaybe component path)
  where
    component (R.Field n) = Just n
    component (R.Argument n) = Just ("@argument:" ++ n)
    component (R.TagName n) = Just ("@tag:" ++ n)
    component (R.Branch _ n) = Just ("@branch:" ++ n)
    component _ = Nothing
    location declaration prefix = locationSpan <$> find
      (\l -> locationDeclaration l == declaration && locationPath l == prefix) locations
    definition seen name rest
      | name `elem` seen = Nothing
      | otherwise = M.lookup name (O.declarations syntax) >>= descend (name:seen) name [] rest
    descend seen declaration prefix rest expression =
      let own = location declaration prefix
          child n t remaining = descend seen declaration (prefix ++ [n]) remaining t
      in case (rest, expression) of
        ([], _) -> own
        (_, O.Named n) -> definition seen n rest <|> own
        (_, O.Collection t) -> descend seen declaration prefix rest t
        (_, O.Unique _ t) -> descend seen declaration prefix rest t
        (_, O.Intersection ts) -> listToMaybe (mapMaybe (descend seen declaration prefix rest) ts)
        (n:ns, O.Object fs) -> do
          field <- find ((== n) . O.fieldExprName) fs
          child n (O.fieldExprType field) ns
        (n:ns, O.Alternative tag bs)
          | n == "@tag:" ++ tag -> location declaration (prefix ++ ["@tag:" ++ tag])
          | otherwise -> do
              branch <- find ((== n) . ("@branch:" ++) . O.branchExprName) bs
              child n (O.branchExprType branch) ns
        (n:ns, O.Function ps result) -> case find ((== n) . ("@argument:" ++) . O.parameterExprName) ps of
          Just p -> child n (O.parameterExprType p) ns
          Nothing -> descend seen declaration prefix rest result
        _ -> Nothing

segment :: R.Segment -> String
segment (R.Field n) = n
segment (R.Argument n) = "(" ++ n ++ ")"
segment (R.TagName n) = "<" ++ n ++ ">"
segment (R.Branch t n) = "<" ++ t ++ "=" ++ n ++ ">"
segment R.Elements = "[]"
segment R.Entries = "()"
segment R.Slot = "#"

fieldID :: String -> R.Path -> String
fieldID pop path = pop ++ ":" ++ intercalate "." (map segment path)

atoms :: R.Path -> R.Row -> [(R.Path, R.Atom)]
atoms prefix row = [(prefix ++ R.columnPath c, R.columnAtom c) | c <- R.columns row]
  ++ concat [ [(prefix ++ R.dependentPath d ++ R.keyPath k, R.keyAtom k) | k <- R.addedKey d]
              ++ atoms (prefix ++ R.dependentPath d) (R.contents d) | d <- R.dependents row]

literalJSON :: O.Literal -> Value
literalJSON (O.TextLiteral x) = toJSON x
literalJSON (O.NumberLiteral x) = toJSON x
literalJSON (O.BooleanLiteral x) = toJSON x

atomJSON :: R.Atom -> Value
atomJSON (R.ScalarAtom p) = object ["kind" .= primitive p]
atomJSON (R.LiteralAtom x) = object ["kind" .= literalKind x, "values" .= [literalJSON x]]
atomJSON (R.EnumAtom xs) = object ["kind" .= maybe "string" literalKind (listToMaybe xs), "values" .= map literalJSON xs]
atomJSON (R.ReferenceAtom target) = object ["kind" .= ("reference" :: String), "target" .= target]

primitive :: O.Primitive -> String
primitive O.TString = "string"
primitive O.TNumber = "number"
primitive O.TBoolean = "boolean"
primitive O.TTimestamp = "timestamp"

literalKind :: O.Literal -> String
literalKind (O.TextLiteral _) = "string"
literalKind (O.NumberLiteral _) = "number"
literalKind (O.BooleanLiteral _) = "boolean"

sqlType :: S.SqlType -> String
sqlType S.SqlText = "text"
sqlType S.SqlNumeric = "numeric"
sqlType S.SqlBigInt = "bigint"
sqlType S.SqlBoolean = "boolean"
sqlType S.SqlTimestamp = "timestamptz"
sqlType S.SqlJsonb = "jsonb"
sqlType S.SqlDouble = "double precision"

referenceJSON :: P.PgReference -> Value
referenceJSON r = object ["fields" .= P.pgReferenceFields r, "target" .= P.pgReferenceTarget r,
  "targetFields" .= P.pgReferenceTargetFields r]

compileOntology :: String -> String -> Either String Value
compileOntology root source = do
  (syntax, locations) <- parseModuleLocated "ontology.ontology" source
  ontology <- checkOntology root syntax
  meaning <- R.relational root ontology
  physical <- P.postgres meaning
  let fieldAtoms = [(pop, path, atom) | (pop,p) <- M.toAscList (R.populations meaning),
        (path,atom) <- nubBy (\a b -> fst a == fst b) (atoms [] (R.populationValue p))]
      fields = [object ["id" .= fieldID pop path, "population" .= pop,
        "path" .= map segment path, "label" .= intercalate "." (map segment path),
        "atom" .= atomJSON atom, "source" .= spanJSON (sourceFor syntax locations pop path)]
        | (pop,path,atom) <- fieldAtoms]
      tableJSON table =
        let (pop,prefix) = P.pgValueOrigin table
            binding name = lookup name [(column,path) | (path,column) <- P.pgBindings table]
            sourceAt path = sourceFor syntax locations pop (prefix ++ path)
            columnJSON c = object ["name" .= P.pgColumnName c, "type" .= sqlType (P.pgColumnType c),
              "nullable" .= P.pgColumnNullable c, "generated" .= P.pgColumnGenerated c,
              "guards" .= P.pgColumnPresence c,
              "field" .= fmap (fieldID pop . (prefix ++)) (binding (P.pgColumnName c)),
              "source" .= spanJSON (binding (P.pgColumnName c) >>= sourceAt)]
            branch = listToMaybe [object ["field" .= tag, "value" .= value]
              | P.RequiredAlternative _ _ tag value child _ <- P.pgIntegrity physical,
                child == P.pgTableName table]
            presence = [marker | P.DependentRequiresPresence _ _ marker child _ <- P.pgIntegrity physical,
              child == P.pgTableName table]
        in object ["name" .= P.pgTableName table, "path" .= P.pgSemanticPath table,
          "population" .= pop, "source" .= spanJSON (sourceAt []),
          "columns" .= map columnJSON (P.pgColumns table), "primaryKey" .= P.pgPrimaryKey table,
          "unique" .= map P.pgUniqueFields (P.pgUnique table),
          "references" .= map referenceJSON (P.pgReferences table),
          "owner" .= fmap referenceJSON (P.pgOwnerReference table),
          "branch" .= branch, "presence" .= presence]
  pure (object ["tables" .= map tableJSON (P.pgTables physical), "fields" .= fields,
    "sql" .= SQL.renderProgram (Physical.program physical)])

compileSelector :: String -> String -> String -> Either String Value
compileSelector root source query = do
  (syntax, _) <- parseModuleLocated "ontology.ontology" source
  ontology <- checkOntology root syntax
  parsed <- either (Left . QP.renderParseError) Right (QP.parseProgram "selector.osql" query)
  checked <- either (Left . QC.renderDiagnostic) Right (QC.checkProgram root ontology parsed)
  compiled <- either (\(Q.LoweringError code message) -> Left (code ++ ": " ++ message)) Right
    (Q.compileProgram "workbench" checked)
  pure (object ["setup" .= SQL.renderProgram (Q.compilationSetup compiled),
    "query" .= SQL.renderQuery (Q.compilationQuery compiled),
    "collection" .= isCollection (Q.compilationType compiled), "type" .= QT.prettyType (Q.compilationType compiled)])
  where
    isCollection (QT.Set _) = True
    isCollection (QT.Sequence _) = True
    isCollection _ = False
