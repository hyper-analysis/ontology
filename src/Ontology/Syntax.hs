module Ontology.Syntax where

import Data.List (intercalate)
import Data.Map.Strict (Map)
import Data.Scientific (Scientific)

type Name = String
type NodeId = Int

data Literal
  = TextLiteral String
  | NumberLiteral Scientific
  | BooleanLiteral Bool
  deriving (Eq, Ord, Show)

data Primitive
  = TString
  | TNumber
  | TBoolean
  | TTimestamp
  deriving (Eq, Ord, Show)

data TypeExpr
  = Primitive Primitive
  | Literal Literal
  | Named Name
  | Object [FieldExpr]
  | Reference Name
  | Collection TypeExpr
  | Unique [Name] TypeExpr
  | Function [ParameterExpr] TypeExpr
  | Alternative Name [BranchExpr]
  | Union [TypeExpr]
  | Intersection [TypeExpr]
  deriving (Eq, Show)

data FieldExpr = FieldExpr
  { fieldExprName :: Name
  , fieldExprOptional :: Bool
  , fieldExprKey :: Bool
  , fieldExprType :: TypeExpr
  } deriving (Eq, Show)

data ParameterExpr = ParameterExpr
  { parameterExprName :: Name
  , parameterExprType :: TypeExpr
  } deriving (Eq, Show)

data BranchExpr = BranchExpr
  { branchExprName :: Name
  , branchExprType :: TypeExpr
  } deriving (Eq, Show)

newtype Module = Module
  { declarations :: Map Name TypeExpr
  } deriving (Eq, Show)

data Node
  = Scalar Primitive
  | ScalarLiteral Literal
  | ScalarEnum [Literal]
  | Record [Field]
  | Ref Name
  | Many NodeId
  | Distinct [Name] NodeId
  | FunctionNode [Parameter] NodeId
  | AlternativeNode Name [Branch]
  deriving (Eq, Show)

data Field = Field
  { fieldName :: Name
  , fieldOptional :: Bool
  , fieldUnique :: Bool
  , fieldKey :: Bool
  , fieldType :: NodeId
  } deriving (Eq, Show)

data Parameter = Parameter
  { parameterName :: Name
  , parameterType :: NodeId
  } deriving (Eq, Show)

data Branch = Branch
  { branchName :: Name
  , branchType :: NodeId
  } deriving (Eq, Show)

data Ontology = Ontology
  { namedNodes :: Map Name NodeId
  , nodes :: Map NodeId Node
  } deriving (Eq, Show)

nodeSummary :: Node -> String
nodeSummary n = case n of
  Scalar p -> show p
  ScalarLiteral l -> show l
  ScalarEnum ls -> "enum " ++ show ls
  Record fs -> "object {" ++ intercalate ", " (map fieldName fs) ++ "}"
  Ref target -> "Ref<" ++ target ++ ">"
  Many x -> "collection #" ++ show x
  Distinct by x -> "distinct" ++ show by ++ " collection #" ++ show x
  FunctionNode ps x -> "(" ++ intercalate ", " [parameterName p ++ ": #" ++ show (parameterType p) | p <- ps] ++ ") => #" ++ show x
  AlternativeNode tag bs -> "alternative " ++ tag ++ " {" ++ intercalate ", " (map branchName bs) ++ "}"

