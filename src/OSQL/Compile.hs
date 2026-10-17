module OSQL.Compile
  ( Compilation(..), LoweringError(..), compileProgram, renderCompilation
  ) where

import Control.Monad (unless, foldM, when)
import Control.Monad.State.Strict (evalStateT)
import Data.Char (isAscii, isAlphaNum)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.Map.Strict as M
import qualified Ontology.Postgres as P
import qualified Ontology.Syntax as O
import qualified SQL.Syntax as Q
import qualified SQL.Render as Render
import SQL.Validate (validateQuery)
import qualified OSQL.Checked as C
import qualified OSQL.Syntax as S
import qualified OSQL.Type as T
import qualified OSQL.Storage as Storage
import OSQL.Target

data Compilation = Compilation
  { compilationSchema :: P.PgSchema
  , compilationSetup :: Q.Program
  , compilationQuery :: Q.Query
  , compilationType :: T.Type
  } deriving (Eq, Show)

data Context = Context
  { store :: Storage.Storage
  , namespace :: String
  , demandFunction :: String
  }

-- The namespace owns a finite set of generated functions in the caller's
-- search_path. No schema or data is installed by this pure compilation step.
compileProgram :: String -> C.CheckedProgram -> Either LoweringError Compilation
compileProgram prefix (C.CheckedProgram signature bindings result) = evalStateT build 0
  where
    build = do
      unless (not (null prefix) && length prefix <= 24 && all (\c -> isAscii c && (isAlphaNum c || c == '_')) prefix)
        (unsupported "Use a nonempty ASCII function namespace of at most 24 letters/digits/underscores")
      physical <- checked (P.postgres (C.relational signature))
      (providers,storage) <- Storage.storage prefix signature physical
      let context = Context storage prefix (prefix ++ "_demand")
          demandDefinition = Q.CreateValueFunction (demandFunction context) [Q.SqlJsonb] Q.SqlJsonb
            (scalar (demand (Storage.failureFunction storage) (Q.ParameterValue 1)))
      initial <- define prefix [] [Q.SqlJsonb] (scalar (Q.ParameterValue 1))
      environment <- foldM (definition context) initial bindings
      output <- expression context result
      final <- define prefix [environment,output] [] (scalar (call output [call environment [object []]]))
      let serializerName = prefix ++ "_serialize"
          setup = Q.Program (providers ++ [demandDefinition,serializer serializerName] ++ definitions final)
          queryValue = scalar (Q.FunctionValue serializerName [call final []])
      mapM_ validateDefinition (providers ++ [demandDefinition,serializer serializerName] ++ definitions final)
      checked (validateQuery queryValue)
      pure (Compilation physical setup queryValue (C.exprType result))
    validateDefinition (Q.CreateValueFunction _ _ _ body) = checked (validateQuery body)
    validateDefinition _ = pure ()
    definition context previous (name,value) = do
      evaluated <- expression context value
      stage <- define prefix [evaluated] [Q.SqlJsonb]
        (scalar (extend (Q.ParameterValue 1) name (call evaluated [Q.ParameterValue 1])))
      define prefix [previous,stage] [Q.SqlJsonb] (scalar (call stage [call previous [Q.ParameterValue 1]]))

renderCompilation :: Compilation -> String
renderCompilation compilation = Render.renderProgram (compilationSetup compilation)
  ++ Render.renderQuery (compilationQuery compilation)

failName :: Context -> String
failName = Storage.failureFunction . store

force :: Context -> Q.Value -> Q.Value
force context value = Q.FunctionValue (demandFunction context) [value]

asBoolean :: Context -> Q.Value -> Q.Value
asBoolean context value = Q.CastValue (Q.JsonText (payload (force context value))) Q.SqlBoolean

exprFunction :: Context -> [Function] -> Q.Value -> Build Function
exprFunction context dependencies value = define (namespace context) dependencies [Q.SqlJsonb] (scalar value)

expression :: Context -> C.Expr -> Build Function
expression context checkedExpression = case C.expression checkedExpression of
  C.Variable name -> exprFunction context [] (Q.JsonField env name)
  C.Root -> exprFunction context [] (Q.FunctionValue (Storage.rootFunction (store context)) [])
  C.Literal literal -> literalValue literal >>= exprFunction context []
  C.Record fields -> do
    children <- mapM (expression context . snd) fields
    exprFunction context children (record [(name,call child [env]) | ((name,_),child) <- zip fields children])
  C.Chain headValue suffixes -> do
    first <- expression context headValue
    suffix <- chain context suffixes
    exprFunction context [first,suffix] (call suffix [env,call first [env]])
  C.Match scrutinee arms fallback -> do
    first <- expression context scrutinee
    cases <- mapM (\(label,binder,body) -> do
      function <- expression context body
      pure (label,binder,function)) arms
    defaultCase <- mapM (expression context) fallback
    let current = Q.ParameterValue 2
        namedCases = [(Q.Equals (Q.JsonText (Q.JsonField current "branch")) (Q.TextValue label),
          call function [extend env binder (payload current)]) | (label,binder,function) <- cases]
        defaultValue = maybe (failure (failName context) Q.IntegrityFailure) (\f -> call f [env]) defaultCase
        selected = case namedCases of [] -> defaultValue; x:xs -> Q.CaseValue (x :| xs) defaultValue
        demanded = Q.CaseValue ((isNull current,failure (failName context) Q.MissingValue) :| []) selected
    dispatcher <- define (namespace context) ([f | (_,_,f) <- cases] ++ maybe [] (:[]) defaultCase)
      [Q.SqlJsonb,Q.SqlJsonb] (scalar demanded)
    exprFunction context [first,dispatcher] (call dispatcher [env,call first [env]])
  C.Exists mode value -> do
    child <- expression context value
    let lengthValue = Q.JsonLength (payload (force context (Q.ParameterValue 1)))
        test = case mode of S.NonEmptyResult -> Q.Compare Q.Greater lengthValue (Q.NumberValue 0)
                            S.UniqueResult -> Q.Equals lengthValue (Q.NumberValue 1)
    operation <- define (namespace context) [] [Q.SqlJsonb] (scalar (condition test))
    exprFunction context [child,operation] (call operation [call child [env]])
  C.Quantified quantifier name range body -> do
    rangeFunction <- expression context range
    predicate <- expression context body
    alias <- fresh "quantified"
    let current = Q.OutputColumn alias "value"
        test = asBoolean context (call predicate [extend env name current])
        operation = case quantifier of S.Some -> Q.AnyTrue; S.Every -> Q.AllTrue
        empty = Q.BoolValue (quantifier == S.Every)
        values = Q.JsonItems alias (payload (force context (Q.ParameterValue 2)))
        result = Q.ScalarQuery (query (Q.Coalesce (Q.BoolAggregate operation test :| [empty])) (Just values) (Q.And []) False)
    evaluator <- define (namespace context) [predicate] [Q.SqlJsonb,Q.SqlJsonb] (scalar (atom "Boolean" result))
    exprFunction context [rangeFunction,evaluator] (call evaluator [env,call rangeFunction [env]])
  C.Builtin builtin value -> do
    child <- expression context value
    operator <- builtinFunction context builtin
    exprFunction context [child,operator] (call operator [call child [env]])
  C.At _ _ -> unsupported "Sequence indexing requires an ordinal-bearing ontology sequence; this storage has none"
  C.Select queryValue -> queryFunction context queryValue
  C.Not value -> do
    child <- expression context value
    operator <- define (namespace context) [] [Q.SqlJsonb]
      (scalar (condition (Q.Not (Q.BooleanValue (asBoolean context (Q.ParameterValue 1))))))
    exprFunction context [child,operator] (call operator [call child [env]])
  C.Binary op left right -> binary context op left right
  where
    env = Q.ParameterValue 1
    literalValue (S.TextLiteral value) = pure (atom "Text" (Q.TextValue value))
    literalValue (S.BooleanLiteral value) = pure (atom "Boolean" (Q.BoolValue value))
    literalValue S.NullLiteral = pure nullValue
    literalValue (S.NumberLiteral (S.Decimal coefficient exponentValue)) = do
      let digits = toInteger (length (show (abs coefficient)))
      when (coefficient /= 0 && (digits + exponentValue > 131072 || exponentValue < -16383))
        (unsupported "Exact decimal exceeds PostgreSQL numeric precision/range")
      pure (atom "Number" (Q.DecimalValue coefficient exponentValue))
    literalValue (S.TimestampLiteral value) = do
      let fraction = takeWhile (/= 'Z') (drop 1 (dropWhile (/= '.') value))
      when (length fraction > 6 || take 4 value == "0000" || take 1 value == "-")
        (unsupported "Timestamp instant exceeds PostgreSQL's supported literal precision/range (microseconds)")
      pure (atom "Timestamp" (Q.CastValue (Q.TextValue value) Q.SqlTimestamp))

chain :: Context -> [C.Postfix] -> Build Function
chain context [] = define (namespace context) [] [Q.SqlJsonb,Q.SqlJsonb] (scalar (Q.ParameterValue 2))
chain context (suffix:remaining) = do
  rest <- chain context remaining
  let environment = Q.ParameterValue 1
      receiver = Q.ParameterValue 2
  case suffix of
    C.Field optional input name _ -> do
      value <- fieldValue context input name receiver
      let active = call rest [environment,value]
          absent = if optional then nullValue else failure (failName context) Q.MissingValue
      define (namespace context) [rest] [Q.SqlJsonb,Q.SqlJsonb]
        (scalar (Q.CaseValue ((isNull receiver,absent) :| []) active))
    C.Apply input args _ -> do
      let expressions = case args of C.Positional value -> [value]; C.Named fields -> map snd fields
      children <- mapM (expression context) expressions
      application <- applicationFunction context input args
      let applied = call application (receiver : [force context (call child [environment]) | child <- children])
      define (namespace context) (rest:children ++ [application]) [Q.SqlJsonb,Q.SqlJsonb]
        (scalar (Q.CaseValue ((isNull receiver,failure (failName context) Q.MissingValue) :| [])
          (call rest [environment,applied])))

fieldValue :: Context -> T.Type -> String -> Q.Value -> Build Q.Value
fieldValue context input name receiver = do
  active <- maybe (unsupported "Null has no field owner") pure (T.nonNull input)
  select active
  where
    select (T.Record _) = pure (Q.JsonField (payload receiver) name)
    select (T.Entity population) = do
      function <- checked (maybe (Left ("Unknown population " ++ population)) Right
        (M.lookup population (Storage.recordFunctions (store context))))
      pure (Q.JsonField (payload (Q.FunctionValue function [receiver])) name)
    select (T.Union alternatives) = do
      cases <- mapM (\t -> do
        value <- select t
        predicate <- case t of
          T.Entity population -> pure (Q.And [Q.Equals (kind receiver) (Q.TextValue "Entity"),
            Q.Equals (Q.JsonText (Q.JsonField receiver "p")) (Q.TextValue population)])
          T.Record _ -> pure (Q.Equals (kind receiver) (Q.TextValue "Record"))
          _ -> unsupported "Unsupported field union owner"
        pure (predicate,value)) alternatives
      case cases of
        first:rest -> pure (Q.CaseValue (first :| rest) (failure (failName context) Q.IntegrityFailure))
        [] -> unsupported "Empty field-owner union"
    select _ = unsupported "Checked field has no record/entity owner"

applicationFunction :: Context -> T.Type -> C.Arguments -> Build Function
applicationFunction context input args = do
  active <- maybe (unsupported "Null is not callable") pure (T.nonNull input)
  let alternatives = case active of T.Union xs -> xs; _ -> [active]
      callee = Q.ParameterValue 1
      members = payload callee
      first = Q.JsonElement members 0
      empty = Q.Equals (Q.JsonLength members) (Q.NumberValue 0)
  finish <- define (namespace context) [] [Q.SqlJsonb]
    (scalar (Q.CaseValue
      ((Q.Compare Q.Greater (Q.JsonLength (Q.ParameterValue 1)) (Q.NumberValue 1),failure (failName context) Q.IntegrityFailure) :| [])
      (Q.Coalesce (Q.JsonElement (Q.ParameterValue 1) 0 :| [nullValue]))))
  cases <- mapM (\t -> do
    (parameters,predicate) <- case t of
      T.Set (T.Entity population) -> do
        fields <- Storage.keyFields (store context) population
        pure (map O.fieldName fields,Q.And [Q.Equals (kind callee) (Q.TextValue "Set"),
          Q.Or [empty,Q.Equals (Q.JsonText (Q.JsonField first "p")) (Q.TextValue population)]])
      T.Map fields _ -> do
        let key = payload (Q.JsonField (payload first) "key")
        pure (map fst fields,Q.And [Q.Equals (kind callee) (Q.TextValue "Map"),
          Q.Or [empty,Q.And [Q.IsNotNull (Q.JsonField key name) | (name,_) <- fields]]])
      _ -> unsupported "Checked callee has no map/key signature"
    let actualNames = case args of C.Positional _ -> parameters; C.Named fields -> map fst fields
        supplied = record [(name,Q.ParameterValue index) | (index,name) <- zip [2..] actualNames]
    alias <- fresh "lookup"
    let member = Q.OutputColumn alias "value"
        (key,result) = case t of
          T.Set _ -> (Q.JsonField member "k",member)
          _ -> (Q.JsonField (payload member) "key",Q.JsonField (payload member) "value")
    matches <- setArray (query result (Just (Q.JsonItems alias members)) (Q.Equals key supplied) True)
    function <- define (namespace context) [] (replicate (length actualNames + 1) Q.SqlJsonb)
      (scalar (call finish [matches]))
    pure (predicate,function)) alternatives
  let arity = case args of C.Positional _ -> 2; C.Named fields -> length fields + 1
      values = map Q.ParameterValue [1..arity]
      arms = [(predicate,call function values) | (predicate,function) <- cases]
  case arms of
    firstArm:rest -> define (namespace context) (finish:map snd cases) (replicate arity Q.SqlJsonb)
      (scalar (Q.CaseValue (firstArm :| rest) (failure (failName context) Q.IntegrityFailure)))
    [] -> unsupported "Empty callee union"

builtinFunction :: Context -> S.UnaryBuiltin -> Build Function
builtinFunction context builtin = do
  let value = force context (Q.ParameterValue 1)
      members = payload value
      result = case builtin of
        S.Count -> atom "Number" (Q.JsonLength members)
        S.Entries -> envelope "Set" members
        S.Only -> Q.CaseValue
          ((Q.Equals (Q.JsonLength members) (Q.NumberValue 1),Q.JsonElement members 0) :| [])
          (failure (failName context) Q.CardinalityFailure)
        S.First -> Q.Coalesce (Q.JsonElement members 0 :| [nullValue])
  define (namespace context) [] [Q.SqlJsonb] (scalar result)

binary :: Context -> S.BinaryOp -> C.Expr -> C.Expr -> Build Function
binary context op left right = do
  a <- expression context left
  b <- expression context right
  case op of
    S.And -> lazy a b False False
    S.Or -> lazy a b True True
    S.Implies -> lazy a b False True
    _ -> do
      let x = Q.ParameterValue 1
          y = Q.ParameterValue 2
      test <- case op of
        S.Equal -> pure (Q.NullSafeEquals x y)
        S.Member -> do
          alias <- fresh "membership"
          pure (Q.ExistsQuery (query (Q.NumberValue 1)
            (Just (Q.JsonItems alias (payload (force context y)))) (Q.NullSafeEquals x (Q.OutputColumn alias "value")) False))
        _ -> do
          let timestamp = maybe False (`T.assignable` T.Primitive O.TTimestamp) (T.nonNull (C.exprType left))
              sqlType = if timestamp then Q.SqlTimestamp else Q.SqlNumeric
              scalarValue v = Q.CastValue (Q.JsonText (payload (force context v))) sqlType
          comparison <- case op of
            S.Less -> pure Q.Less
            S.LessEqual -> pure Q.LessEqual
            S.Greater -> pure Q.Greater
            S.GreaterEqual -> pure Q.GreaterEqual
          pure (Q.Compare comparison (scalarValue x) (scalarValue y))
      operator <- define (namespace context) [] [Q.SqlJsonb,Q.SqlJsonb] (scalar (condition test))
      exprFunction context [a,b,operator] (call operator [call a [env],call b [env]])
  where
    env = Q.ParameterValue 1
    lazy a b skipWhen skipped = do
      let test = Q.Equals (asBoolean context (Q.ParameterValue 2)) (Q.BoolValue skipWhen)
      operator <- define (namespace context) [b] [Q.SqlJsonb,Q.SqlJsonb]
        (scalar (Q.CaseValue ((test,atom "Boolean" (Q.BoolValue skipped)) :| []) (force context (call b [env]))))
      exprFunction context [a,operator] (call operator [env,call a [env]])

queryFunction :: Context -> C.Query -> Build Function
queryFunction context (C.Query selection sources steps projection) = do
  sourceFunctions <- mapM (\(name,source) -> do
    value <- expression context source
    alias <- fresh "environment"
    memberAlias <- fresh "member"
    let environment = Q.OutputColumn alias "value"
        member = Q.OutputColumn memberAlias "value"
        sourceValue = force context (call value [environment])
        from = Q.Cross (Q.JsonItems alias (Q.ParameterValue 1)) (Q.JsonItems memberAlias (payload sourceValue))
    results <- array (extend environment name member) (Just from) (Q.And [])
    define (namespace context) [value] [Q.SqlJsonb] (scalar results)) sources
  stepFunctions <- mapM stage steps
  output <- expression context projection
  alias <- fresh "projection"
  results <- setArray (query (call output [Q.OutputColumn alias "value"])
    (Just (Q.JsonItems alias (Q.ParameterValue 1))) (Q.And []) True)
  projected <- define (namespace context) [output] [Q.SqlJsonb] (scalar (envelope "Set" results))
  let rows = foldl (\previous f -> call f [previous]) (Q.JsonArrayValues [Q.ParameterValue 1]) (sourceFunctions ++ stepFunctions)
      setResult = call projected [rows]
      dependencies = sourceFunctions ++ stepFunctions ++ [projected]
  case selection of
    S.AllResults -> exprFunction context dependencies setResult
    S.SingleResult -> do
      only <- builtinFunction context S.Only
      exprFunction context (dependencies ++ [only]) (call only [setResult])
  where
    stage (C.Let name value) = do
      evaluated <- expression context value
      alias <- fresh "environment"
      let environment = Q.OutputColumn alias "value"
      results <- array (extend environment name (call evaluated [environment]))
        (Just (Q.JsonItems alias (Q.ParameterValue 1))) (Q.And [])
      define (namespace context) [evaluated] [Q.SqlJsonb] (scalar results)
    stage (C.Where value) = do
      evaluated <- expression context value
      alias <- fresh "environment"
      let environment = Q.OutputColumn alias "value"
      results <- array environment (Just (Q.JsonItems alias (Q.ParameterValue 1)))
        (Q.BooleanValue (asBoolean context (call evaluated [environment])))
      define (namespace context) [evaluated] [Q.SqlJsonb] (scalar results)

