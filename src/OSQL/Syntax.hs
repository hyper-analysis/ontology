module OSQL.Syntax
  ( Name, Position(..), SourceSpan(..), Located(..)
  , Program(..), Binding, BindingNode(..), Expr, ExprNode(..)
  , Primary, PrimaryNode(..), Literal(..), Decimal(..)
  , Postfix, PostfixNode(..), Arguments(..)
  , Query(..), Selection(..), Projection(..), Source, SourceNode(..)
  , Step, StepNode(..), MatchArms(..), CaseArm, CaseArmNode(..)
  , Existence(..), Quantifier(..), UnaryBuiltin(..), BinaryOp(..)
  ) where

import Data.List.NonEmpty (NonEmpty)

type Name = String

data Position = Position
  { positionOffset :: Int
  , positionLine :: Int
  , positionColumn :: Int
  } deriving (Eq, Show)

data SourceSpan = SourceSpan
  { spanFile :: FilePath
  , spanStart :: Position
  , spanEnd :: Position
  } deriving (Eq, Show)

data Located a = Located
  { sourceSpan :: SourceSpan
  , syntax :: a
  } deriving (Eq, Show)

data Program = Program [Binding] Expr
  deriving (Eq, Show)

type Binding = Located BindingNode
data BindingNode = Binding Name Expr
  deriving (Eq, Show)

type Expr = Located ExprNode

data ExprNode
  = PostfixExpr Primary [Postfix]
  | Group Expr
  | Select Query
  | Not Expr
  | Binary BinaryOp Expr Expr
  deriving (Eq, Show)

-- A grouped expression is not a primary: it cannot acquire a postfix suffix.
-- All field labels are literal source names, never expressions.
type Primary = Located PrimaryNode

data PrimaryNode
  = Variable Name
  | Root
  | Literal Literal
  | Record [(Name, Expr)]
  | Match Expr MatchArms
  | Exists Existence Expr
  | Quantified Quantifier Name Expr Expr
  | Builtin UnaryBuiltin Expr
  | At Expr Expr
  deriving (Eq, Show)

data Literal
  = TextLiteral String
  | NumberLiteral Decimal
  | BooleanLiteral Bool
  | TimestampLiteral String
  | NullLiteral
  deriving (Eq, Show)

-- Exact coefficient * 10^exponent; no floating-point conversion or bounded
-- machine exponent is introduced by source parsing.
data Decimal = Decimal Integer Integer
  deriving (Eq, Show)

type Postfix = Located PostfixNode

data PostfixNode
  = Field Name
  | OptionalField Name
  | Apply Arguments
  deriving (Eq, Show)

data Arguments
  = Positional Expr
  | Named (NonEmpty (Name, Expr))
  deriving (Eq, Show)

data Query = Query
  { querySelection :: Selection
  , queryProjection :: Projection
  , querySources :: NonEmpty Source
  , querySteps :: [Step]
  } deriving (Eq, Show)

data Selection = AllResults | SingleResult
  deriving (Eq, Show)

data Projection
  = Single Expr
  | NamedProjection (NonEmpty (Name, Expr))
  deriving (Eq, Show)

type Source = Located SourceNode
data SourceNode = Source Expr Name
  deriving (Eq, Show)

type Step = Located StepNode
data StepNode = Let Binding | Where Expr
  deriving (Eq, Show)

data MatchArms
  = NamedArms (NonEmpty CaseArm) (Maybe Expr)
  | DefaultOnly Expr
  deriving (Eq, Show)

type CaseArm = Located CaseArmNode
data CaseArmNode = CaseArm Name Name Expr
  deriving (Eq, Show)

data Existence = NonEmptyResult | UniqueResult
  deriving (Eq, Show)

data Quantifier = Some | Every
  deriving (Eq, Show)

data UnaryBuiltin = Count | Entries | Only | First
  deriving (Eq, Show)

data BinaryOp
  = Equal | Less | LessEqual | Greater | GreaterEqual | Member
  | And | Or | Implies
  deriving (Eq, Show)

