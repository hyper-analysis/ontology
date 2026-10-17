-- Small target equations shared by storage interpretation and expression lowering.
module OSQL.Target where

import Control.Monad.State.Strict
import Data.List.NonEmpty (NonEmpty(..))
import qualified SQL.Syntax as Q
import SQL.Validate (validateQuery)

data LoweringError = LoweringError String String deriving (Eq, Show)
type Build = StateT Integer (Either LoweringError)

data Function = Function { definitions :: [Q.Statement], functionName :: String }
  deriving (Eq, Show)

unsupported :: String -> Build a
unsupported = lift . Left . LoweringError "UnsupportedLowering"

checked :: Either String a -> Build a
checked = either (lift . Left . LoweringError "StorageMapping") pure

fresh :: String -> Build String
fresh prefix = do
  n <- get
  put (n + 1)
  pure (prefix ++ "_" ++ show n)

query :: Q.Value -> Maybe Q.From -> Q.Expr -> Bool -> Q.Query
query value source predicate distinctness = Q.SelectQuery (Q.Output "value" value :| []) source predicate distinctness []

scalar :: Q.Value -> Q.Query
scalar value = query value Nothing (Q.And []) False

object :: [(String,Q.Value)] -> Q.Value
object fields = Q.JsonValue (Q.JsonObject [(name,Q.JsonScalar value) | (name,value) <- fields])

nullValue :: Q.Value
nullValue = Q.JsonValue Q.JsonNull

emptyArray :: Q.Value
emptyArray = Q.JsonArrayValues []

envelope :: String -> Q.Value -> Q.Value
envelope name value = object [("t",Q.TextValue name),("v",value)]

record :: [(String,Q.Value)] -> Q.Value
record = envelope "Record" . object

atom :: String -> Q.Value -> Q.Value
atom = envelope

payload :: Q.Value -> Q.Value
payload value = Q.JsonField value "v"

kind :: Q.Value -> Q.Value
kind value = Q.JsonText (Q.JsonField value "t")

call :: Function -> [Q.Value] -> Q.Value
call function = Q.FunctionValue (functionName function)

condition :: Q.Expr -> Q.Value
condition = atom "Boolean" . Q.ConditionValue

failure :: String -> Q.RuntimeFailure -> Q.Value
failure name outcome = Q.FailureValue name outcome Q.SqlJsonb

isNull :: Q.Value -> Q.Expr
isNull value = Q.NullSafeEquals value nullValue

demand :: String -> Q.Value -> Q.Value
demand name value = Q.CaseValue ((isNull value,failure name Q.MissingValue) :| []) value

boolean :: String -> Q.Value -> Q.Value
boolean name = (\value -> Q.CastValue (Q.JsonText (payload value)) Q.SqlBoolean) . demand name

extend :: Q.Value -> String -> Q.Value -> Q.Value
extend environment name value = Q.JsonValue (Q.JsonMerge [Q.JsonScalar environment,Q.JsonScalar (object [(name,value)])])

-- Every returned array is canonical: DISTINCT typed values, ordered by JSONB
-- comparison. This is an internal set representation, not a source sequence.
setArray :: Q.Query -> Build Q.Value
setArray rows = do
  alias <- fresh "set_rows"
  let value = Q.OutputColumn alias "value"
  pure (Q.ScalarQuery (query (Q.Coalesce (Q.JsonAggregate value [value] :| [emptyArray]))
    (Just (Q.Derived alias Q.Independent rows)) (Q.And []) False))

array :: Q.Value -> Maybe Q.From -> Q.Expr -> Build Q.Value
array value source predicate = do
  alias <- fresh "array_rows"
  let rows = query value source predicate False
  pure (Q.ScalarQuery (query (Q.Coalesce (Q.JsonAggregate (Q.OutputColumn alias "value") [] :| [emptyArray]))
    (Just (Q.Derived alias Q.Independent rows)) (Q.And []) False))

define :: String -> [Function] -> [Q.SqlType] -> Q.Query -> Build Function
define prefix dependencies parameters body = do
  name <- fresh prefix
  checked (validateQuery body)
  pure (Function (concatMap definitions dependencies ++ [Q.CreateValueFunction name parameters Q.SqlJsonb body]) name)

-- Generic, recursive transport interpretation of the closed internal value
-- algebra. Entity designators expose semantic keys; they never expand a cycle.
serializer :: String -> Q.Statement
serializer name = Q.CreateValueFunction name [Q.SqlJsonb] Q.SqlJsonb (scalar result)
  where
    value = Q.ParameterValue 1
    contents = payload value
    recurse v = Q.FunctionValue name [v]
    pairs = Q.JsonPairs "fields" contents
    objects = Q.ScalarQuery (query (Q.Coalesce
      (Q.JsonObjectAggregate (Q.OutputColumn "fields" "key") (recurse (Q.OutputColumn "fields" "value")) :| [object []]))
      (Just pairs) (Q.And []) False)
    items = Q.JsonItems "items" contents
    arrays = Q.ScalarQuery (query (Q.Coalesce
      (Q.JsonAggregate (recurse (Q.OutputColumn "items" "value")) [] :| [emptyArray]))
      (Just items) (Q.And []) False)
    entity = object [("$entity",Q.JsonField value "p"),("key",recurse (Q.JsonField value "k"))]
    variant = object [("$variant",Q.JsonField value "tag"),("branch",Q.JsonField value "branch"),("value",recurse contents)]
    result = Q.CaseValue
      ((isNull value,nullValue) :|
       [(Q.Equals (kind value) (Q.TextValue "Record"),objects)
       ,(Q.Or [Q.Equals (kind value) (Q.TextValue t) | t <- ["Set","Sequence","Map"]],arrays)
       ,(Q.Equals (kind value) (Q.TextValue "Entity"),entity)
       ,(Q.Equals (kind value) (Q.TextValue "Variant"),variant)]) contents

