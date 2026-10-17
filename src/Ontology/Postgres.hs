module Ontology.Postgres
  ( PgSchema(..), PgTable(..), PgColumn(..), PgReference(..), PgUnique(..)
  , SelectorSource(..), PgIntegrity(..), SemanticPath, SemanticOrigin
  , postgres, postgresSummary, localProgram, tableForPath, columnForPath
  , tableForValue, tableNamed, atomType
  ) where

import Control.Monad (unless)
import Data.Char (isAlphaNum, isAscii, toLower)
import Data.List (intercalate, nub, isPrefixOf, sortOn)
import Data.Maybe (listToMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Ontology.Relational as R
import qualified Ontology.Syntax as O
import qualified SQL.Syntax as SQL

type SemanticPath = [String]
type SemanticOrigin = (String, R.Path)

data PgColumn = PgColumn
  { pgColumnName :: String, pgColumnType :: SQL.SqlType
  , pgColumnNullable :: Bool, pgColumnGenerated :: Bool
  , pgColumnPresence :: [String]
  } deriving (Eq, Show)
data PgReference = PgReference
  { pgReferenceFields :: [String], pgReferenceTarget :: String
  , pgReferenceTargetFields :: [String]
  } deriving (Eq, Show)
data PgUnique = PgUnique
  { pgUniqueFields :: [String], pgNullsNotDistinct :: Bool } deriving (Eq, Show)
data SelectorSource = SelectorSource
  { selectorSourceTable :: String, selectorSourceOwnerKey :: [String]
  , selectorSourceOccurrence :: String, selectorSourceFields :: [String]
  } deriving (Eq, Show)
data PgIntegrity
  = RequiredAlternative
      { integrityOwnerTable :: String, integrityOwnerKey :: [String]
      , integrityTagField :: String, integrityTagValue :: String
      , integrityBranchTable :: String, integrityBranchKey :: [String] }
  | DependentRequiresPresence
      { integrityParentTable :: String, integrityParentKey :: [String]
      , integrityPresenceField :: String, integrityDependentTable :: String
      , integrityDependentKey :: [String] }
  | StructuredDistinctness
      { integrityCollectionTable :: String, integrityCollectionOwnerKey :: [String]
      , integrityCollectionOccurrence :: String, integritySelectors :: [String]
      , integritySelectorSources :: [SelectorSource] }
  deriving (Eq, Show)

data PgTable = PgTable
  { pgTableName :: String
  , pgSemanticPath :: SemanticPath
  , pgColumns :: [PgColumn]
  , pgPrimaryKey :: [String]
  , pgUnique :: [PgUnique]
  , pgReferences :: [PgReference]
  , pgChecks :: [SQL.Expr]
  -- Generated together with the layout, not reverse-engineered by the reader.
  , pgValueOrigin :: SemanticOrigin
  , pgBindings :: [(R.Path, String)]
  , pgPresenceBindings :: [(R.Path, String)]
  , pgOwnerReference :: Maybe PgReference
  } deriving (Eq, Show)
data PgSchema = PgSchema
  { pgTables :: [PgTable], pgIntegrity :: [PgIntegrity] } deriving (Eq, Show)

data Key = Key
  { keyName :: String, keyType :: SQL.SqlType
  , keyGenerated :: Bool, keyReference :: Maybe String
  } deriving (Eq, Show)
data Seed = Seed
  { seedPath :: SemanticPath, seedOwner :: Maybe SemanticPath
  , seedOwnerKey :: [Key], seedKey :: [Key], seedRow :: R.Row
  , seedBoundary :: Maybe R.Boundary, seedPresence :: [R.Presence]
  , seedPopulationKey :: [R.KeyColumn], seedOrigin :: SemanticOrigin
  , seedLocalKey :: [(R.KeyColumn, Key)]
  } deriving (Eq, Show)

segmentName :: R.Segment -> String
segmentName (R.Field n) = n
segmentName (R.Argument n) = n
segmentName (R.TagName n) = n
segmentName (R.Branch t n) = t ++ "_" ++ n
segmentName R.Elements = "items"
segmentName R.Entries = "entries"
segmentName R.Slot = "occurrence"

clean :: String -> String
clean = collapse . map normalize
  where
    normalize c | isAscii c && isAlphaNum c = toLower c
                | otherwise = '_'
    collapse [] = []
    collapse ('_':'_':xs) = collapse ('_':xs)
    collapse (x:xs) = x : collapse xs

fieldName :: R.Path -> String
fieldName [] = "value"
fieldName xs = clean (intercalate "_" (map segmentName xs))

assignTableNames :: [Seed] -> M.Map SemanticPath String
assignTableNames ss = M.fromList
  [(seedPath s, numbered i (clean (intercalate "_" (seedPath s))))
  | (i, s) <- zip [1 :: Int ..] ss]
  where
    numbered i base = let prefix = "t" ++ show i ++ "_"
                      in prefix ++ take (63 - length prefix) base

atomType :: R.Atom -> SQL.SqlType
atomType (R.ScalarAtom O.TString) = SQL.SqlText
atomType (R.ScalarAtom O.TNumber) = SQL.SqlNumeric
atomType (R.ScalarAtom O.TBoolean) = SQL.SqlBoolean
atomType (R.ScalarAtom O.TTimestamp) = SQL.SqlTimestamp
atomType (R.LiteralAtom x) = literalType x
atomType (R.EnumAtom (x:_)) = literalType x
atomType (R.EnumAtom []) = SQL.SqlText
atomType (R.ReferenceAtom _) = SQL.SqlBigInt

literalType :: O.Literal -> SQL.SqlType
literalType (O.TextLiteral _) = SQL.SqlText
literalType (O.NumberLiteral _) = SQL.SqlNumeric
literalType (O.BooleanLiteral _) = SQL.SqlBoolean

literalValue :: O.Literal -> SQL.Value
literalValue (O.TextLiteral x) = SQL.TextValue x
literalValue (O.NumberLiteral x) = SQL.NumberValue (toRational x)
literalValue (O.BooleanLiteral x) = SQL.BoolValue x

atomCheck :: String -> R.Atom -> [SQL.Expr]
atomCheck name (R.LiteralAtom x) = [SQL.Equals (SQL.ColumnValue Nothing name) (literalValue x)]
atomCheck name (R.EnumAtom xs) =
  [SQL.Or [SQL.Equals (SQL.ColumnValue Nothing name) (literalValue x) | x <- xs]]
atomCheck _ _ = []

presenceName :: R.Presence -> String
presenceName (R.PresentWhen p) = "__present_" ++ fieldName p

entityKey :: Key
entityKey = Key "id" SQL.SqlBigInt True Nothing

keyFromAtom :: String -> R.Atom -> Key
keyFromAtom name atom = Key name (atomType atom) False
  (case atom of R.ReferenceAtom target -> Just target; _ -> Nothing)

addedKey :: R.Path -> R.KeyColumn -> Key
addedKey p k = keyFromAtom
  (case reverse p of R.Elements:_ -> fieldName (R.keyPath k)
                     _ -> fieldName (p ++ R.keyPath k)) (R.keyAtom k)

populationPath :: R.Relational -> String -> SemanticPath
populationPath meaning name = M.findWithDefault [name] name
  (M.fromList [(n, [field]) | (field, n) <- R.rootPopulations meaning])

seeds :: R.Relational -> [Seed]
seeds meaning = concat [populationSeeds n p | (n, p) <- M.toAscList (R.populations meaning)]
  where
    populationSeeds name p =
      let path = populationPath meaning name
          row = R.populationValue p
          root = Seed path Nothing [] [entityKey] row Nothing []
            (R.populationKey p) (name, []) []
      in root : children root
    children parent = concatMap (dependentSeed parent) (R.dependents (seedRow parent))
    dependentSeed parent d =
      let path = R.dependentPath d
          (pop, prefix) = seedOrigin parent
          reserved = map keyName (seedKey parent)
            ++ [fieldName (R.columnPath c) | R.FunctionBoundary <- [R.boundary d], c <- R.columns (R.contents d)]
          local = allocate reserved [(k, addedKey path k) | k <- R.addedKey d]
          child = Seed (seedPath parent ++ map segmentName path) (Just (seedPath parent))
            (seedKey parent) (seedKey parent ++ map snd local) (R.contents d)
            (Just (R.boundary d)) (R.dependentPresence d) [] (pop, prefix ++ path) local
      in child : children child
    allocate _ [] = []
    allocate taken ((semantic, physical):rest) =
      let candidates = keyName physical : [keyName physical ++ "_k" ++ show n | n <- [1 :: Int ..]]
          chosen = head (filter (`notElem` taken) candidates)
      in (semantic, physical { keyName = chosen }) : allocate (chosen:taken) rest

postgres :: R.Relational -> Either String PgSchema
postgres meaning = do
  let ss = seeds meaning
      names = assignTableNames ss
      targets = M.fromList [(n, names M.! populationPath meaning n) | n <- M.keys (R.populations meaning)]
  unless (length ss == M.size names) (Left "Colliding physical table paths")
  tables <- mapM (compileSeed names targets) ss
  pure (PgSchema tables (concatMap (compileIntegrity names) ss))

compileSeed :: M.Map SemanticPath String -> M.Map String String -> Seed -> Either String PgTable
compileSeed names targets seed = do
  name <- maybe (Left "Missing generated table name") Right (M.lookup (seedPath seed) names)
  let ownerNames = map keyName (seedOwnerKey seed)
      keys = [PgColumn (keyName k) (keyType k) False
               (keyGenerated k && keyName k `notElem` ownerNames) [] | k <- seedKey seed]
      row = seedRow seed
      presences = S.toAscList (S.fromList
        (concatMap R.columnPresence (R.columns row)
          ++ concatMap R.dependentPresence (R.dependents row)
          ++ [R.PresentWhen p | R.OptionalValue p <- R.rules row]))
      markers = [PgColumn (presenceName p) SQL.SqlBoolean False False [] | p <- presences]
      values = [PgColumn (fieldName (R.columnPath c)) (atomType (R.columnAtom c))
                 (not (null (R.columnPresence c))) False (map presenceName (R.columnPresence c))
               | c <- R.columns row]
      owner = do
        path <- seedOwner seed
        table <- M.lookup path names
        pure (PgReference ownerNames table ownerNames)
      atomRefs = [PgReference [pgColumnName c] target ["id"]
                 | (c, r) <- zip values (R.columns row)
                 , R.ReferenceAtom n <- [R.columnAtom r], Just target <- [M.lookup n targets]]
      keyRefs = [PgReference [keyName k] target ["id"]
                | k <- seedKey seed, Just n <- [keyReference k], Just target <- [M.lookup n targets]]
      bindings = nub ([(R.columnPath c, pgColumnName p) | (c, p) <- zip (R.columns row) values]
                  ++ [(R.keyPath k, keyName p) | (k, p) <- seedLocalKey seed])
      checks = concat [atomCheck (pgColumnName p) (R.columnAtom c) | (p, c) <- zip values (R.columns row)]
        ++ concat [atomCheck (keyName p) (R.keyAtom k) | (k, p) <- seedLocalKey seed]
        ++ presenceChecks presences (R.columns row)
      setUnique = case seedBoundary seed of
        Just (R.CollectionBoundary (R.DistinctBy selectors)) -> [PgUnique (ownerNames ++ map clean selectors) True]
        _ -> []
      populationUnique = [PgUnique (map (fieldName . R.keyPath) (seedPopulationKey seed)) True
                         | seedOwner seed == Nothing, not (null (seedPopulationKey seed))]
  unless (length (nub (map snd bindings)) == length bindings)
    (Left ("Different semantic values share a SQL column in " ++ name))
  unless (null [pgColumnName c | c <- values, pgColumnName c `elem` ownerNames
                    || (seedOwner seed == Nothing && pgColumnName c == "id")])
    (Left ("A value column collides with an inherited storage key in " ++ name))
  cols <- uniqueColumns (keys ++ markers ++ values)
  pure PgTable
    { pgTableName = name, pgSemanticPath = seedPath seed, pgColumns = cols
    , pgPrimaryKey = map keyName (seedKey seed)
    , pgUnique = nub (concatMap (compileRule cols) (R.rules row) ++ setUnique ++ populationUnique)
    , pgReferences = nub (maybe [] (:[]) owner ++ atomRefs ++ keyRefs)
    , pgChecks = checks, pgValueOrigin = seedOrigin seed, pgBindings = bindings
    , pgPresenceBindings = [(p, presenceName (R.PresentWhen p)) | R.PresentWhen p <- presences]
    , pgOwnerReference = owner
    }

compileRule :: [PgColumn] -> R.Rule -> [PgUnique]
compileRule _ (R.OptionalValue _) = []
compileRule cols (R.UniqueValue path) =
  let prefix = fieldName path
      matches = [pgColumnName c | c <- cols, pgColumnName c == prefix
                            || (prefix ++ "_") `isPrefixOf` pgColumnName c]
  in [PgUnique matches True | not (null matches)]

uniqueColumns :: [PgColumn] -> Either String [PgColumn]
uniqueColumns cols = do
  let names = nub (map pgColumnName cols)
  mapM_ check names
  pure [head [c | c <- cols, pgColumnName c == n] | n <- names]
  where
    check name = do
      unless (length name <= 63) (Left ("SQL column name exceeds identifier limit: " ++ name))
      case [c | c <- cols, pgColumnName c == name] of
        [] -> pure ()
        first:rest -> unless (all (sameShape first) rest) (Left ("SQL column collision: " ++ name))
    sameShape a b = pgColumnType a == pgColumnType b
      && pgColumnNullable a == pgColumnNullable b && pgColumnGenerated a == pgColumnGenerated b

presenceChecks :: [R.Presence] -> [R.Column] -> [SQL.Expr]
presenceChecks presences cols =
  [SQL.Or [SQL.And [active, SQL.IsNotNull value], SQL.And [SQL.Not active, SQL.IsNull value]]
  | c <- cols, not (null (R.columnPresence c))
  , let active = SQL.And (map marker (R.columnPresence c))
        value = SQL.ColumnValue Nothing (fieldName (R.columnPath c))]
  ++ [SQL.Or [SQL.Not (marker child), marker parent]
     | child@(R.PresentWhen p) <- presences, parent@(R.PresentWhen q) <- presences
     , q /= p, q `isPrefixOf` p]
  where marker p = SQL.Equals (SQL.ColumnValue Nothing (presenceName p)) (SQL.BoolValue True)

compileIntegrity :: M.Map SemanticPath String -> Seed -> [PgIntegrity]
compileIntegrity names seed = case seedOwner seed of
  Nothing -> []
  Just ownerPath -> case (M.lookup ownerPath names, M.lookup (seedPath seed) names) of
    (Just parent, Just child) ->
      [RequiredAlternative parent keys (fieldName tag) branch child keys
      | Just (R.AlternativeBoundary tag branch) <- [seedBoundary seed]]
      ++ [DependentRequiresPresence parent keys (presenceName p) child keys | p <- seedPresence seed]
    _ -> []
  where keys = map keyName (seedOwnerKey seed)

toSqlColumn :: PgColumn -> SQL.Column
toSqlColumn c = SQL.Column (pgColumnName c) (pgColumnType c)
  (if pgColumnNullable c then SQL.Nullable else SQL.NotNull)
  (if pgColumnGenerated c then SQL.Identity else SQL.Supplied)

toSqlLocalConstraints :: PgTable -> [SQL.Constraint]
toSqlLocalConstraints t = [SQL.PrimaryKey (pgPrimaryKey t)]
  ++ [SQL.Unique (pgUniqueFields u) (if pgNullsNotDistinct u then SQL.NullsNotDistinct else SQL.NullsDistinct)
     | u <- pgUnique t]
  ++ map SQL.Check (pgChecks t)

toSqlReference :: PgReference -> SQL.Constraint
toSqlReference r = SQL.ForeignKey (pgReferenceFields r) (pgReferenceTarget r)
  (pgReferenceTargetFields r) SQL.Deferred

localProgram :: PgSchema -> SQL.Program
localProgram schema = SQL.Program
  ([SQL.CreateTable (SQL.Table (pgTableName t) (map toSqlColumn (pgColumns t)) (toSqlLocalConstraints t))
   | t <- pgTables schema]
   ++ [SQL.AlterTableAddConstraint (pgTableName t) (toSqlReference r)
      | t <- pgTables schema, r <- pgReferences t])

tableForPath :: PgSchema -> SemanticPath -> Either String PgTable
tableForPath schema path = uniqueTable (show path) [t | t <- pgTables schema, pgSemanticPath t == path]

tableNamed :: PgSchema -> String -> Either String PgTable
tableNamed schema name = uniqueTable name [t | t <- pgTables schema, pgTableName t == name]

-- A nested inline field belongs to the most specific containing value table.
-- This lookup uses typed semantic provenance, not spelling conventions.
tableForValue :: PgSchema -> SemanticOrigin -> Either String PgTable
tableForValue schema (pop, path) =
  maybe (Left ("No storage location for " ++ show (pop, path))) Right
    (listToMaybe (reverse (sortOn (length . snd . pgValueOrigin)
      [t | t <- pgTables schema, let (p, prefix) = pgValueOrigin t, p == pop, prefix `isPrefixOf` path])))

uniqueTable :: String -> [PgTable] -> Either String PgTable
uniqueTable _ [t] = Right t
uniqueTable label [] = Left ("No PostgreSQL table for " ++ label)
uniqueTable label _ = Left ("Ambiguous PostgreSQL table for " ++ label)

columnForPath :: R.Path -> String
columnForPath = fieldName

postgresSummary :: PgSchema -> String
postgresSummary schema = unlines (concatMap showTable (pgTables schema)
  ++ ["Integrity:"] ++ map (("  " ++) . show) (pgIntegrity schema))
  where
    showTable t =
      [pgTableName t ++ "  <=  " ++ intercalate "." (pgSemanticPath t)
      ,"  key: " ++ intercalate ", " (pgPrimaryKey t)]
      ++ ["  column: " ++ pgColumnName c ++ " :: " ++ show (pgColumnType c)
          ++ (if pgColumnNullable c then " ?" else "") | c <- pgColumns t]
      ++ ["  fk: " ++ intercalate "," (pgReferenceFields r) ++ " -> " ++ pgReferenceTarget r | r <- pgReferences t]
      ++ ["  unique: " ++ intercalate "," (pgUniqueFields u) | u <- pgUnique t] ++ [""]

