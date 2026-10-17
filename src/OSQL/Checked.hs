-- Internal checked representation. Public clients obtain it through OSQL.Check.
module OSQL.Checked where

import qualified Data.Map.Strict as M
import qualified Ontology.Syntax as O
import qualified Ontology.Relational as R
import qualified OSQL.Syntax as S
import OSQL.Type (Type)

data Signature = Signature
  { ontology :: O.Ontology
  , rootName :: String
  , relational :: R.Relational
  , entityNames :: M.Map O.NodeId String
  , rootType :: Type
  } deriving (Eq, Show)

data CheckedProgram = CheckedProgram Signature [(String, Expr)] Expr
  deriving (Eq, Show)

data Expr = Expr { location :: S.SourceSpan, exprType :: Type, expression :: Node }
  deriving (Eq, Show)

data Node
  = Variable String
  | Root
  | Literal S.Literal
  | Record [(String, Expr)]
  | Chain Expr [Postfix]
  | Match Expr [(String, String, Expr)] (Maybe Expr)
  | Exists S.Existence Expr
  | Quantified S.Quantifier String Expr Expr
  | Builtin S.UnaryBuiltin Expr
  | At Expr Expr
  | Select Query
  | Not Expr
  | Binary S.BinaryOp Expr Expr
  deriving (Eq, Show)

data Postfix
  = Field Bool Type String Type
  | Apply Type Arguments Type
  deriving (Eq, Show)

data Arguments = Positional Expr | Named [(String, Expr)]
  deriving (Eq, Show)

data Query = Query S.Selection [(String, Expr)] [Step] Expr
  deriving (Eq, Show)

data Step = Let String Expr | Where Expr
  deriving (Eq, Show)

