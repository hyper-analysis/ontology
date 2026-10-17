module SQL.Syntax where

import Data.List.NonEmpty (NonEmpty)
import qualified SQL.Reference as Ref

type Name = String
type Alias = String

data SqlType = SqlText | SqlBoolean | SqlDouble | SqlTimestamp | SqlBigInt
  | SqlNumeric | SqlJsonb
  deriving (Eq, Show)
data Nullability = Nullable | NotNull deriving (Eq, Show)
data Generation = Supplied | Identity deriving (Eq, Show)

data Column = Column
  { columnName :: Name
  , columnType :: SqlType
  , columnNullability :: Nullability
  , columnGeneration :: Generation
  } deriving (Eq, Show)

data NullEquality = NullsDistinct | NullsNotDistinct deriving (Eq, Show)
data Deferrability = Immediate | Deferred deriving (Eq, Show)
data Constraint
  = PrimaryKey [Name]
  | Unique [Name] NullEquality
  | ForeignKey [Name] Name [Name] Deferrability
  | Check Expr
  deriving (Eq, Show)
data Table = Table
  { tableName :: Name
  , tableColumns :: [Column]
  , tableConstraints :: [Constraint]
  } deriving (Eq, Show)

data Value
  = ColumnValue (Maybe Alias) Name
  | ParameterValue Int
  | TextValue String
  | NumberValue Rational
  | BoolValue Bool
  | NullValue
  | BoundColumn Ref.ColumnUse
  | OutputColumn Alias Name
  | RowValue Alias
  | DecimalValue Integer Integer
  | CastValue Value SqlType
  | CaseValue (NonEmpty (Expr, Value)) Value
  | ConditionValue Expr
  | JsonValue JsonExpr
  | ScalarQuery Query
  | CountRows
  | CountValue Value
  | CountDistinct Value
  | JsonAggregate Value [Value]
  | JsonElement Value Int
  | Coalesce (NonEmpty Value)
  | FailureValue Name RuntimeFailure SqlType
  | FunctionValue Name [Value]
  | JsonField Value Name
  | JsonText Value
  | JsonLength Value
  | JsonArrayValues [Value]
  | JsonObjectAggregate Value Value
  | BoolAggregate BoolAggregation Value
  deriving (Eq, Show)
data Expr
  = Equals Value Value
  | IsNull Value
  | IsNotNull Value
  | And [Expr]
  | Or [Expr]
  | Not Expr
  | Exists Select
  | Compare Comparison Value Value
  | NullSafeEquals Value Value
  | BooleanValue Value
  | ExistsQuery Query
  deriving (Eq, Show)

data Comparison = Less | LessEqual | Greater | GreaterEqual
  deriving (Eq, Show)

data BoolAggregation = AllTrue | AnyTrue deriving (Eq, Show)

data RuntimeFailure = MissingValue | CardinalityFailure | IntegrityFailure
  deriving (Eq, Show)
data Select = Select
  { selectFrom :: Name
  , selectAlias :: Alias
  , selectWhere :: Expr
  } deriving (Eq, Show)

data Procedure = If Expr [Procedure] | RaiseConstraint Name String | ReturnNull
  deriving (Eq, Show)
data Function = Function
  { functionName :: Name
  , functionBody :: [Procedure]
  } deriving (Eq, Show)
data Event = Insert | Update | Delete deriving (Eq, Show)
data Trigger = Trigger
  { triggerName :: Name
  , triggerTable :: Name
  , triggerEvents :: [Event]
  , triggerDeferred :: Bool
  , triggerFunction :: Name
  } deriving (Eq, Show)

-- No raw SQL escape hatch. One/array is the cardinality interpretation.
-- JsonOne deliberately has no LIMIT: more than one row is an invariant error.
data JsonExpr
  = JsonScalar Value
  | JsonObject [(String, JsonExpr)]
  | JsonArray Query
  | JsonOne Query
  | JsonNullable Expr JsonExpr
  | JsonCase Expr JsonExpr JsonExpr
  | JsonMerge [JsonExpr]
  | JsonNull
  deriving (Eq, Show)

data Query
  = Query
      { queryExpression :: JsonExpr
      , queryFrom :: Name
      , queryAlias :: Alias
      , queryWhere :: Expr
      , queryOrderBy :: [Value]
      , queryJoins :: [(Name, Alias)]
      }
  | ValueQuery JsonExpr
  | SelectQuery
      { queryOutputs :: NonEmpty Output
      , querySource :: Maybe From
      , queryWhere :: Expr
      , queryDistinct :: Bool
      , queryOrderBy :: [Value]
      }
  deriving (Eq, Show)

data Output = Output Name Value
  deriving (Eq, Show)

data From
  = Stored Ref.TableUse
  | Derived Alias Correlation Query
  | Cross From From
  | Join JoinKind From From Expr
  | JsonItems Alias Value
  | JsonPairs Alias Value
  deriving (Eq, Show)

data Correlation = Independent | Lateral
  deriving (Eq, Show)

data JoinKind = InnerJoin | LeftJoin
  deriving (Eq, Show)

data Statement
  = CreateTable Table
  | AlterTableAddConstraint Name Constraint
  | CreateFunction Function
  | CreateConstraintTrigger Trigger
  | CreateReadFunction Name [SqlType] Query
  | CreateFailureFunction Name
  | CreateValueFunction Name [SqlType] SqlType Query
  deriving (Eq, Show)
newtype Program = Program [Statement] deriving (Eq, Show)

