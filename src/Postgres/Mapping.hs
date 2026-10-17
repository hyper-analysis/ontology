-- Reusable storage resolution for any query frontend. No view/projection import.
module Postgres.Mapping
  ( BoundTable, bindAt, bindNamed, binding, columnAt, presenceAt, correlate
  , ownerCondition, referenceCondition
  ) where

import Control.Monad (unless)
import qualified Ontology.Postgres as P
import qualified Ontology.Relational as R
import qualified SQL.Reference as Ref
import qualified SQL.Syntax as SQL

data BoundTable = BoundTable P.PgTable Ref.TableUse
  deriving (Eq, Show)

bindAt :: P.PgSchema -> P.SemanticOrigin -> SQL.Alias -> Either String BoundTable
bindAt schema origin alias = P.tableForValue schema origin >>= bind alias

bindNamed :: P.PgSchema -> SQL.Name -> SQL.Alias -> Either String BoundTable
bindNamed schema name alias = P.tableNamed schema name >>= bind alias

bind :: SQL.Alias -> P.PgTable -> Either String BoundTable
bind alias table = do
  reference <- Ref.tableReference (P.pgTableName table) (map P.pgColumnName (P.pgColumns table))
  use <- Ref.useTable reference alias
  pure (BoundTable table use)

binding :: BoundTable -> Ref.TableUse
binding (BoundTable _ use) = use

columnAt :: BoundTable -> R.Path -> Either String SQL.Value
columnAt (BoundTable table use) path = do
  name <- maybe (Left ("No stored column for " ++ show path)) Right (lookup path (P.pgBindings table))
  SQL.BoundColumn <$> Ref.columnReference use name

presenceAt :: BoundTable -> R.Path -> Either String SQL.Value
presenceAt (BoundTable table use) path = do
  name <- maybe (Left ("No stored presence marker for " ++ show path)) Right (lookup path (P.pgPresenceBindings table))
  SQL.BoundColumn <$> Ref.columnReference use name

correlate :: BoundTable -> P.PgReference -> BoundTable -> Either String SQL.Expr
correlate (BoundTable source left) reference (BoundTable target right) = do
  unless (reference `elem` P.pgReferences source
      && P.pgReferenceTarget reference == P.pgTableName target
      && not (null (P.pgReferenceFields reference))
      && length (P.pgReferenceFields reference) == length (P.pgReferenceTargetFields reference))
    (Left "Foreign-key correspondence does not connect these table bindings")
  tests <- mapM equal (zip (P.pgReferenceFields reference) (P.pgReferenceTargetFields reference))
  pure (SQL.And tests)
  where
    equal (a, b) = SQL.Equals
      <$> (SQL.BoundColumn <$> Ref.columnReference left a)
      <*> (SQL.BoundColumn <$> Ref.columnReference right b)

ownerCondition :: BoundTable -> BoundTable -> Either String SQL.Expr
ownerCondition child@(BoundTable table _) parent = do
  owner <- maybe (Left "Table has no physical owner reference") Right (P.pgOwnerReference table)
  correlate child owner parent

referenceCondition :: BoundTable -> R.Path -> BoundTable -> Either String SQL.Expr
referenceCondition source@(BoundTable table _) path target@(BoundTable targetTable _) = do
  value <- columnAt source path
  name <- case value of
    SQL.BoundColumn column -> Right (Ref.physicalColumnName column)
    _ -> Left "Reference is not a physical column"
  case [reference | reference <- P.pgReferences table,
        P.pgReferenceFields reference == [name],
        P.pgReferenceTarget reference == P.pgTableName targetTable] of
    [reference] -> correlate source reference target
    _ -> Left "No unique foreign key at this semantic reference site"

