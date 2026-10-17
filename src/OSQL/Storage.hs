-- Interpret checked ownership/value shapes using the generated storage catalog.
-- It builds queries; no views, projection cutoffs or guessed physical names.
module OSQL.Storage
  ( Storage(..), storage, entityFields, keyFields ) where

import Control.Monad (when, unless)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.Map.Strict as M
import qualified Ontology.Syntax as O
import qualified Ontology.Relational as R
import qualified Ontology.Postgres as P
import qualified Postgres.Mapping as Mapping
import qualified SQL.Reference as Ref
import qualified SQL.Syntax as Q
import qualified OSQL.Checked as C
import OSQL.Target

data Storage = Storage
  { signature :: C.Signature
  , schema :: P.PgSchema
  , rootFunction :: String
  , failureFunction :: String
  , keyFunctions :: M.Map String String
  , recordFunctions :: M.Map String String
  } deriving (Eq, Show)

storage :: String -> C.Signature -> P.PgSchema -> Build ([Q.Statement],Storage)
storage prefix signatures physical = do
  let populations = M.keys (R.populations (C.relational signatures))
      keyNames = M.fromList [(p,prefix ++ "_key_" ++ show n) | (n,p) <- zip [1::Int ..] populations]
      recordNames = M.fromList [(p,prefix ++ "_record_" ++ show n) | (n,p) <- zip [1::Int ..] populations]
      context = Storage signatures physical (prefix ++ "_root") (prefix ++ "_failure") keyNames recordNames
  mapM_ (finiteKey context []) populations
  -- The old storage interpretation gives aliased populations separate tables.
  -- Do not silently equate those independent physical populations.
  identifiers <- mapM (named signatures) populations
  unless (length identifiers == length (nub identifiers))
    (unsupported "Aliased identity populations have separate storage tables")
  keys <- mapM (keyDefinition context) populations
  records <- mapM (recordDefinition context) populations
  root <- rootDefinition context
  pure (Q.CreateFailureFunction (failureFunction context) : keys ++ records ++ [root],context)

named :: C.Signature -> String -> Build O.NodeId
named signatures name = checked (maybe (Left ("Unknown type " ++ name)) Right
  (M.lookup name (O.namedNodes (C.ontology signatures))))

node :: C.Signature -> O.NodeId -> Build O.Node
node signatures ident = checked (maybe (Left "Missing checked ontology node") Right
  (M.lookup ident (O.nodes (C.ontology signatures))))

entityFields :: Storage -> String -> Build [O.Field]
entityFields context population = do
  ident <- named (signature context) population
  value <- node (signature context) ident
  case value of O.Record fields -> pure fields; _ -> unsupported "An identity population must be a record"

keyFields :: Storage -> String -> Build [O.Field]
keyFields context population = filter O.fieldKey <$> entityFields context population

finiteKey :: Storage -> [String] -> String -> Build ()
finiteKey context ancestors population = do
  when (population `elem` ancestors) (unsupported "Cyclic semantic identity keys have no finite transport value")
  fields <- keyFields context population
  mapM_ (visit . O.fieldType) fields
  where
    visit ident = do
      value <- node (signature context) ident
      case value of
        O.Ref target -> finiteKey context (population:ancestors) target
        O.Record fields -> mapM_ (visit . O.fieldType) fields
        O.Scalar _ -> pure ()
        O.ScalarLiteral _ -> pure ()
        O.ScalarEnum _ -> pure ()
        _ -> unsupported "Non-keyable semantic identity field"

lookupFunction :: M.Map String String -> String -> Build String
lookupFunction functions population = checked (maybe (Left ("No population provider for " ++ population)) Right (M.lookup population functions))

bind :: Storage -> (String,R.Path) -> Build Mapping.BoundTable
bind context origin = do
  alias <- fresh "stored"
  bound <- checked (Mapping.bindAt (schema context) origin alias)
  table <- checked (P.tableForValue (schema context) origin)
  unless (P.pgValueOrigin table == origin) (unsupported ("Expected a storage boundary at " ++ show origin))
  pure bound

column :: Mapping.BoundTable -> R.Path -> Build Q.Value
column bound = checked . Mapping.columnAt bound

identity :: Mapping.BoundTable -> Build Q.Value
identity bound = do
  unless ("id" `elem` Ref.physicalColumnNames (Ref.usedTable (Mapping.binding bound)))
    (unsupported "Population storage has no identity column")
  Q.BoundColumn <$> checked (Ref.columnReference (Mapping.binding bound) "id")

required :: Storage -> Q.Query -> Q.Value
required context rows = Q.Coalesce (Q.ScalarQuery rows :| [failure (failureFunction context) Q.IntegrityFailure])

entity :: String -> Q.Value -> Q.Value
entity population key = object [("t",Q.TextValue "Entity"),("p",Q.TextValue population),("k",key)]

keyValue :: Storage -> String -> Mapping.BoundTable -> Build Q.Value
keyValue context population bound = do
  fields <- keyFields context population
  record <$> mapM (\f -> (,) (O.fieldName f) <$> stored context population bound [R.Field (O.fieldName f)] (O.fieldType f)) fields

keyDefinition :: Storage -> String -> Build Q.Statement
keyDefinition context population = do
  bound <- bind context (population,[])
  ident <- identity bound
  key <- keyValue context population bound
  name <- lookupFunction (keyFunctions context) population
  pure (Q.CreateValueFunction name [Q.SqlBigInt] Q.SqlJsonb
    (scalar (required context (query key (Just (Q.Stored (Mapping.binding bound))) (Q.Equals ident (Q.ParameterValue 1)) False))))

recordDefinition :: Storage -> String -> Build Q.Statement
recordDefinition context population = do
  bound <- bind context (population,[])
  fields <- entityFields context population
  key <- keyValue context population bound
  value <- storedRecord context population bound [] fields
  name <- lookupFunction (recordFunctions context) population
  pure (Q.CreateValueFunction name [Q.SqlJsonb] Q.SqlJsonb
    (scalar (required context (query value (Just (Q.Stored (Mapping.binding bound)))
      (Q.Equals key (Q.JsonField (Q.ParameterValue 1) "k")) False))))

rootDefinition :: Storage -> Build Q.Statement
rootDefinition context = do
  rootId <- named (signature context) (C.rootName (signature context))
  rootNode <- node (signature context) rootId
  fields <- case rootNode of O.Record fs -> pure fs; _ -> unsupported "Non-record root"
  when (any O.fieldOptional fields) (unsupported "Optional root populations have no persisted root-presence marker")
  populations <- mapM population (R.rootPopulations (C.relational (signature context)))
  pure (Q.CreateValueFunction (rootFunction context) [] Q.SqlJsonb (scalar (record populations)))
  where
    population (fieldName,pop) = do
      bound <- bind context (pop,[])
      key <- keyValue context pop bound
      values <- setArray (query (entity pop key) (Just (Q.Stored (Mapping.binding bound))) (Q.And []) True)
      pure (fieldName,envelope "Set" values)

-- path is relative to the current table's semantic origin. Entering a storage
-- boundary resets it; inline record access only extends it.
stored :: Storage -> String -> Mapping.BoundTable -> R.Path -> O.NodeId -> Build Q.Value
stored context population bound path ident = node (signature context) ident >>= interpret
  where
    interpret (O.Scalar p) = storedAtom context bound path p
    interpret (O.ScalarLiteral literal) = storedAtom context bound path (literalPrimitive literal)
    interpret (O.ScalarEnum literals) = do
      let primitives = nub (map literalPrimitive literals)
      case primitives of
        [p] -> storedAtom context bound path p
        _ -> unsupported "Mixed primitive enum storage has no single physical scalar type"
    interpret (O.Ref target) = do
      value <- column bound path
      function <- lookupFunction (keyFunctions context) target
      pure (entity target (Q.FunctionValue function [value]))
    interpret (O.Record fields) = storedRecord context population bound path fields
    interpret (O.Many _) = unsupported "Ordered ontology sequences have no persisted ordinal in this storage interpretation"
    interpret (O.Distinct _ child) = do
      values <- dependent context population bound (path ++ [R.Elements]) $ \member ->
        stored context population member [] child
      packed <- setArray values
      pure (envelope "Set" packed)
    interpret (O.FunctionNode parameters result) = do
      values <- dependent context population bound (path ++ [R.Entries]) $ \entry -> do
        keys <- mapM (\p -> (,) (O.parameterName p) <$> stored context population entry [R.Argument (O.parameterName p)] (O.parameterType p)) parameters
        value <- stored context population entry [] result
        pure (record [("key",record keys),("value",value)])
      packed <- setArray values
      pure (envelope "Map" packed)
    interpret (O.AlternativeNode tag branches) = do
      discriminator <- column bound (path ++ [R.TagName tag])
      cases <- mapM (\branch -> do
        rows <- dependent context population bound (path ++ [R.Branch tag (O.branchName branch)]) $ \payloadRow ->
          stored context population payloadRow [] (O.branchType branch)
        let value = object [("t",Q.TextValue "Variant"),("tag",Q.TextValue tag),
                            ("branch",Q.TextValue (O.branchName branch)),("v",required context rows)]
        pure (Q.Equals discriminator (Q.TextValue (O.branchName branch)),value)) branches
      case cases of
        first:rest -> pure (Q.CaseValue (first :| rest) (failure (failureFunction context) Q.IntegrityFailure))
        [] -> unsupported "Empty named alternative"

storedRecord :: Storage -> String -> Mapping.BoundTable -> R.Path -> [O.Field] -> Build Q.Value
storedRecord context population bound path fields = record <$> mapM field fields
  where
    field f = do
      let fieldPath = path ++ [R.Field (O.fieldName f)]
      value <- stored context population bound fieldPath (O.fieldType f)
      present <- if O.fieldOptional f
        then do
          marker <- checked (Mapping.presenceAt bound fieldPath)
          pure (Q.CaseValue ((Q.BooleanValue marker,value) :| []) nullValue)
        else pure value
      pure (O.fieldName f,present)

dependent :: Storage -> String -> Mapping.BoundTable -> R.Path -> (Mapping.BoundTable -> Build Q.Value) -> Build Q.Query
dependent context population parent relative value = do
  -- Obtain the actual occurrence origin through the table reference, not a
  -- table-number convention. Nested collections/maps/alternatives keep owners.
  actual <- checked (P.tableNamed (schema context) (Ref.physicalTableName (Ref.usedTable (Mapping.binding parent))))
  let origin = snd (P.pgValueOrigin actual) ++ relative
  child <- bind context (population,origin)
  correlation <- checked (Mapping.ownerCondition child parent)
  payloadValue <- value child
  pure (query payloadValue (Just (Q.Stored (Mapping.binding child))) correlation True)

literalPrimitive :: O.Literal -> O.Primitive
literalPrimitive (O.TextLiteral _) = O.TString
literalPrimitive (O.NumberLiteral _) = O.TNumber
literalPrimitive (O.BooleanLiteral _) = O.TBoolean

storedAtom :: Storage -> Mapping.BoundTable -> R.Path -> O.Primitive -> Build Q.Value
storedAtom context bound path primitive = do
  value <- column bound path
  case primitive of
    O.TString -> pure (atom "Text" value)
    O.TBoolean -> pure (atom "Boolean" value)
    O.TTimestamp -> pure (atom "Timestamp" value)
    O.TNumber -> do
      table <- checked (P.tableNamed (schema context) (Ref.physicalTableName (Ref.usedTable (Mapping.binding bound))))
      name <- case value of Q.BoundColumn c -> pure (Ref.physicalColumnName c); _ -> unsupported "Nonphysical number field"
      case [P.pgColumnType c | c <- P.pgColumns table, P.pgColumnName c == name] of
        [Q.SqlNumeric] -> pure ()
        _ -> unsupported "Exact O-SQL numbers require numeric storage; this catalog uses floating point"
      let nonfinite = Q.Or [Q.Equals value (Q.CastValue (Q.TextValue n) Q.SqlNumeric) | n <- ["NaN","Infinity","-Infinity"]]
      pure (Q.CaseValue ((nonfinite,failure (failureFunction context) Q.IntegrityFailure) :| []) (atom "Number" value))

