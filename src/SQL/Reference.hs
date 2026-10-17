-- Physical references do not depend on views, queries or SQL rendering.
module SQL.Reference
  ( TableRef, TableUse, ColumnUse
  , tableReference, useTable, columnReference
  , physicalTableName, physicalColumnNames, usedTable, tableAlias
  , columnTableUse, physicalColumnName
  ) where

import Control.Monad (unless)
import Data.List (nub)

data TableRef = TableRef String [String]
  deriving (Eq, Show)

data TableUse = TableUse TableRef String
  deriving (Eq, Show)

data ColumnUse = ColumnUse TableUse String
  deriving (Eq, Show)

tableReference :: String -> [String] -> Either String TableRef
tableReference name columns = do
  unless (validName name && all validName columns) (Left "Empty/NUL physical identifier")
  unless (length columns == length (nub columns)) (Left "Duplicate physical column")
  pure (TableRef name columns)

useTable :: TableRef -> String -> Either String TableUse
useTable table alias = do
  unless (validName alias) (Left "Empty/NUL table alias")
  pure (TableUse table alias)

columnReference :: TableUse -> String -> Either String ColumnUse
columnReference binding name
  | name `elem` physicalColumnNames (usedTable binding) = Right (ColumnUse binding name)
  | otherwise = Left ("Column " ++ show name ++ " does not belong to " ++ physicalTableName (usedTable binding))

validName :: String -> Bool
validName name = not (null name) && '\0' `notElem` name

physicalTableName :: TableRef -> String
physicalTableName (TableRef name _) = name

physicalColumnNames :: TableRef -> [String]
physicalColumnNames (TableRef _ columns) = columns

usedTable :: TableUse -> TableRef
usedTable (TableUse table _) = table

tableAlias :: TableUse -> String
tableAlias (TableUse _ alias) = alias

columnTableUse :: ColumnUse -> TableUse
columnTableUse (ColumnUse binding _) = binding

physicalColumnName :: ColumnUse -> String
physicalColumnName (ColumnUse _ name) = name

