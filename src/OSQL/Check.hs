module OSQL.Check
  ( CheckedProgram, Diagnostic(..), checkProgram, resultType, renderDiagnostic
  ) where

import Control.Monad (unless, when, foldM)
import Data.Char (ord)
import Data.List (nub, sort)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as M
import qualified Data.Scientific as Scientific
import qualified Ontology.Syntax as O
import qualified Ontology.Relational as R
import qualified OSQL.Syntax as S
import qualified OSQL.Checked as C
import OSQL.Checked (CheckedProgram)
import OSQL.Timestamp (normalizeTimestamp)
import OSQL.Type

data Diagnostic = Diagnostic
  { diagnosticCode :: String
  , diagnosticSpan :: S.SourceSpan
  , diagnosticMessage :: String
  } deriving (Eq, Show)

type Environment = M.Map String Type

renderDiagnostic :: Diagnostic -> String
renderDiagnostic (Diagnostic code spanValue message) =
  S.spanFile spanValue ++ ":" ++ show (S.positionLine (S.spanStart spanValue))
    ++ ":" ++ show (S.positionColumn (S.spanStart spanValue)) ++ ": " ++ code ++ ": " ++ message

problem :: S.SourceSpan -> String -> String -> Either Diagnostic a
problem spanValue code message = Left (Diagnostic code spanValue message)

resultType :: CheckedProgram -> Type
resultType (C.CheckedProgram _ _ result) = C.exprType result

checkProgram :: String -> O.Ontology -> S.Program -> Either Diagnostic CheckedProgram
checkProgram root ontology (S.Program bindings result) = do
  signature <- signatureFor root ontology (S.sourceSpan result)
  (environment, definitions) <- foldM (definition signature) (M.empty, []) bindings
  output <- expression signature environment result
  pure (C.CheckedProgram signature definitions output)
  where
    definition signature (environment, definitions) binding = do
      let S.Binding name value = S.syntax binding
      fresh (S.sourceSpan binding) environment name
      checked <- expression signature environment value
      pure (M.insert name (C.exprType checked) environment, definitions ++ [(name,checked)])

signatureFor :: String -> O.Ontology -> S.SourceSpan -> Either Diagnostic C.Signature
signatureFor root ontology spanValue = do
  meaning <- either (problem spanValue "Ontology") Right (R.relational root ontology)
  let declaredNames = M.fromListWith min [(ident,name) | (name,ident) <- M.toList (O.namedNodes ontology)]
      activeNames = M.fromListWith min [(ident,name) | name <- M.keys (R.populations meaning),
        Just ident <- [M.lookup name (O.namedNodes ontology)]]
      names = activeNames `M.union` declaredNames
      provisional = C.Signature ontology root meaning names Null
  rootId <- maybe (problem spanValue "Ontology" ("Unknown root " ++ root)) Right (M.lookup root (O.namedNodes ontology))
  rootNode <- node provisional spanValue rootId
  rootFields <- case rootNode of
    O.Record fields -> mapM (rootField meaning) fields
    _ -> problem spanValue "Ontology" "Root must be a record"
  pure provisional { C.rootType = Record rootFields }
  where
    rootField meaning field = do
      population <- maybe (problem spanValue "Ontology" "Missing root population") Right
        (lookup (O.fieldName field) (R.rootPopulations meaning))
      pure (O.fieldName field, (if O.fieldOptional field then optional else id) (Set (Entity population)))

node :: C.Signature -> S.SourceSpan -> O.NodeId -> Either Diagnostic O.Node
node signature spanValue ident = maybe (problem spanValue "Ontology" ("Missing node " ++ show ident)) Right
  (M.lookup ident (O.nodes (C.ontology signature)))

namedNode :: C.Signature -> S.SourceSpan -> String -> Either Diagnostic O.NodeId
namedNode signature spanValue name = maybe (problem spanValue "Ontology" ("Unknown type " ++ name)) Right
  (M.lookup name (O.namedNodes (C.ontology signature)))

canonical :: C.Signature -> S.SourceSpan -> String -> Either Diagnostic String
canonical signature spanValue name = do
  ident <- namedNode signature spanValue name
  maybe (problem spanValue "Ontology" "Unnamed identity target") Right (M.lookup ident (C.entityNames signature))

ontologyType :: C.Signature -> S.SourceSpan -> O.NodeId -> Either Diagnostic Type
ontologyType signature spanValue ident = node signature spanValue ident >>= meaning
  where
    meaning (O.Scalar p) = Right (Primitive p)
    meaning (O.ScalarLiteral value) = Right (Literal (atomic value))
    meaning (O.ScalarEnum values) = Right (Enum (map atomic values))
    meaning (O.Ref name) = Entity <$> canonical signature spanValue name
    meaning (O.Record fields) = Record <$> mapM fieldType fields
    meaning (O.Many child) = Sequence <$> ontologyType signature spanValue child
    meaning (O.Distinct _ child) = Set <$> ontologyType signature spanValue child
    meaning (O.FunctionNode parameters result) = Map
      <$> mapM (\p -> (,) (O.parameterName p) <$> ontologyType signature spanValue (O.parameterType p)) parameters
      <*> ontologyType signature spanValue result
    meaning (O.AlternativeNode tag branches) = Variant tag
      <$> mapM (\b -> (,) (O.branchName b) <$> ontologyType signature spanValue (O.branchType b)) branches
    fieldType field = do
      t <- ontologyType signature spanValue (O.fieldType field)
      pure (O.fieldName field, (if O.fieldOptional field then optional else id) t)
    atomic (O.TextLiteral x) = Text x
    atomic (O.NumberLiteral x) = Number (decimal (Scientific.coefficient x) (toInteger (Scientific.base10Exponent x)))
    atomic (O.BooleanLiteral x) = Boolean x

fresh :: S.SourceSpan -> Environment -> String -> Either Diagnostic ()
fresh spanValue local name = when (name == "root" || M.member name local)
  (problem spanValue "DuplicateBinding" ("Cannot bind " ++ name ++ " twice in this scope"))

demand :: S.SourceSpan -> Type -> Either Diagnostic Type
demand spanValue = maybe (problem spanValue "NullShape" "Cannot infer an operation from Null alone") Right . nonNull

require :: S.SourceSpan -> Type -> Type -> Either Diagnostic ()
require spanValue actual expected = unless (assignable actual expected)
  (problem spanValue "TypeMismatch" ("Expected " ++ prettyType expected ++ ", received " ++ prettyType actual))

boolean :: C.Expr -> Either Diagnostic ()
boolean value = demand (C.location value) (C.exprType value) >>= \t -> require (C.location value) t (Primitive O.TBoolean)

allTypes :: (Type -> Either Diagnostic Type) -> Type -> Either Diagnostic Type
allTypes f (Union xs) = union <$> mapM (allTypes f) xs
allTypes f t = f t

selectField :: C.Signature -> S.SourceSpan -> String -> Type -> Either Diagnostic Type
selectField signature spanValue name = allTypes select
  where
    select (Entity population) = namedNode signature spanValue population >>= ontologyType signature spanValue >>= select
    select (Record fields) = maybe (problem spanValue "UnknownField" ("Unknown field " ++ name)) Right (lookup name fields)
    select other = problem spanValue "FieldOwner" ("Cannot select " ++ name ++ " from " ++ prettyType other)

collection :: S.SourceSpan -> Bool -> Type -> Either Diagnostic Type
collection spanValue onlySet t = demand spanValue t >>= allTypes element
  where
    element (Set child) = Right child
    element (Sequence child) | not onlySet = Right child
    element other = problem spanValue "CollectionType" ("Expected " ++ (if onlySet then "Set" else "Set or Sequence") ++ ", received " ++ prettyType other)

keySignature :: C.Signature -> S.SourceSpan -> String -> Either Diagnostic [(String,Type)]
keySignature signature spanValue population = do
  ident <- namedNode signature spanValue population
  n <- node signature spanValue ident
  case n of
    O.Record fields -> mapM key [f | f <- fields, O.fieldKey f]
    _ -> problem spanValue "Ontology" "Entity has no record key"
  where
    key f = (,) (O.fieldName f) <$> ontologyType signature spanValue (O.fieldType f)

callable :: C.Signature -> S.SourceSpan -> Type -> Either Diagnostic ([(String,Type)],Type)
callable signature spanValue (Set (Entity name)) = do
  keys <- keySignature signature spanValue name
  pure (keys, optional (Entity name))
callable _ _ (Map parameters result) = Right (parameters, optional result)
callable _ spanValue other = problem spanValue "NotCallable" ("Cannot apply " ++ prettyType other)

arguments :: C.Signature -> Environment -> S.Arguments -> Either Diagnostic C.Arguments
arguments signature environment (S.Positional value) = C.Positional <$> expression signature environment value
arguments signature environment (S.Named fields) = C.Named <$> mapM (\(name,value) -> (,) name <$> expression signature environment value) (NE.toList fields)

checkArguments :: S.SourceSpan -> C.Arguments -> [(String,Type)] -> Either Diagnostic ()
checkArguments spanValue actual expected = do
  values <- case actual of
    C.Positional value -> case expected of
      [(name,_)] -> Right [(name,value)]
      _ -> problem spanValue "ArgumentNames" "Composite arguments require declared names"
    C.Named fields -> do
      let names = map fst fields
      unless (length names == length (nub names) && sort names == sort (map fst expected))
        (problem spanValue "ArgumentNames" ("Expected exactly " ++ show (map fst expected) ++ ", received " ++ show names))
      pure fields
  mapM_ (checkValue values) expected
  where
    checkValue values (name,t) = case lookup name values of
      Nothing -> problem spanValue "ArgumentNames" ("Missing argument " ++ name)
      Just value -> demand (C.location value) (C.exprType value) >>= \actualType -> require (C.location value) actualType t

expression :: C.Signature -> Environment -> S.Expr -> Either Diagnostic C.Expr
expression signature environment source = case S.syntax source of
  S.Group value -> expression signature environment value
  S.PostfixExpr headValue suffixes -> do
    first <- primary signature environment headValue
    (t,skips,postfixes) <- foldM postfix (C.exprType first,False,[]) suffixes
    pure (make (if skips then optional t else t) (C.Chain first postfixes))
  S.Select query -> do
    (checked,t) <- queryExpression signature environment (S.sourceSpan source) query
    pure (make t (C.Select checked))
  S.Not value -> do
    checked <- expression signature environment value
    boolean checked
    pure (make (Primitive O.TBoolean) (C.Not checked))
  S.Binary op left right -> do
    a <- expression signature environment left
    b <- expression signature environment right
    binaryType op a b
    pure (make (Primitive O.TBoolean) (C.Binary op a b))
  where
    spanValue = S.sourceSpan source
    make = C.Expr spanValue
    postfix (input,skips,acc) suffix = do
      active <- demand (S.sourceSpan suffix) input
      case S.syntax suffix of
        S.Field name -> do
          result <- selectField signature (S.sourceSpan suffix) name active
          pure (result,skips,acc ++ [C.Field False input name result])
        S.OptionalField name -> do
          result <- selectField signature (S.sourceSpan suffix) name active
          pure (result,skips || nullable input,acc ++ [C.Field True input name result])
        S.Apply written -> do
          args <- arguments signature environment written
          result <- allTypes (\callee -> do
            (parameters,output) <- callable signature (S.sourceSpan suffix) callee
            checkArguments (S.sourceSpan suffix) args parameters
            pure output) active
          pure (result,skips,acc ++ [C.Apply input args result])
    binaryType S.Equal a b = unless (equalityCompatible (C.exprType a) (C.exprType b))
      (problem spanValue "EqualityType" "The operands have no compatible value shapes")
    binaryType S.Member a b = do
      element <- collection (C.location b) False (C.exprType b)
      unless (equalityCompatible (C.exprType a) element) (problem spanValue "EqualityType" "Membership element has an incompatible type")
    binaryType op a b | op `elem` [S.And,S.Or,S.Implies] = boolean a >> boolean b
    binaryType _ a b = do
      ta <- demand (C.location a) (C.exprType a)
      tb <- demand (C.location b) (C.exprType b)
      unless (any (\p -> assignable ta (Primitive p) && assignable tb (Primitive p)) [O.TNumber,O.TTimestamp])
        (problem spanValue "OrderingType" "Ordering requires two numbers or two timestamps")

primary :: C.Signature -> Environment -> S.Primary -> Either Diagnostic C.Expr
primary signature environment source = case S.syntax source of
  S.Variable name -> maybe (problem spanValue "UnknownName" ("Unknown binding " ++ name)) (\t -> Right (make t (C.Variable name))) (M.lookup name environment)
  S.Root -> Right (make (C.rootType signature) C.Root)
  S.Literal literal -> do
    (value,t) <- literalType literal
    pure (make t (C.Literal value))
  S.Record fields -> do
    values <- record signature environment spanValue fields
    pure (make (Record [(n,C.exprType v) | (n,v) <- values]) (C.Record values))
  S.Match value arms -> do
    scrutinee <- expression signature environment value
    t <- demand (C.location scrutinee) (C.exprType scrutinee)
    branches <- case t of
      Variant _ bs -> Right bs
      _ -> problem spanValue "MatchType" "match requires one declared Variant signature"
    (cases,fallback) <- matchArms branches arms
    let results = [C.exprType result | (_,_,result) <- cases] ++ maybe [] ((:[]) . C.exprType) fallback
    pure (make (union results) (C.Match scrutinee cases fallback))
  S.Exists mode value -> do
    checked <- expression signature environment value
    _ <- collection (C.location checked) True (C.exprType checked)
    pure (make (Primitive O.TBoolean) (C.Exists mode checked))
  S.Quantified quantifier name range body -> do
    checkedRange <- expression signature environment range
    member <- collection (C.location checkedRange) False (C.exprType checkedRange)
    when (name == "root") (problem spanValue "DuplicateBinding" "root is reserved")
    checkedBody <- expression signature (M.insert name member environment) body
    boolean checkedBody
    pure (make (Primitive O.TBoolean) (C.Quantified quantifier name checkedRange checkedBody))
  S.Builtin builtin value -> do
    checked <- expression signature environment value
    t <- builtinType builtin checked
    pure (make t (C.Builtin builtin checked))
  S.At range index -> do
    checkedRange <- expression signature environment range
    checkedIndex <- expression signature environment index
    t <- sequenceType checkedRange
    demand (C.location checkedIndex) (C.exprType checkedIndex) >>= \i -> require (C.location checkedIndex) i (Primitive O.TNumber)
    pure (make (optional t) (C.At checkedRange checkedIndex))
  where
    spanValue = S.sourceSpan source
    make = C.Expr spanValue
    literalType (S.TextLiteral value) = do
      unless (all (\c -> ord c /= 0 && (ord c < 0xd800 || ord c > 0xdfff)) value)
        (problem spanValue "TextLiteral" "NUL and surrogate codepoints are outside the text domain")
      pure (S.TextLiteral value,Literal (Text value))
    literalType (S.NumberLiteral (S.Decimal c e)) = let value = decimal c e in Right (S.NumberLiteral value, Literal (Number value))
    literalType (S.BooleanLiteral value) = Right (S.BooleanLiteral value,Literal (Boolean value))
    literalType (S.TimestampLiteral value) = do
      normalized <- either (problem spanValue "TimestampLiteral") Right (normalizeTimestamp value)
      pure (S.TimestampLiteral normalized,Primitive O.TTimestamp)
    literalType S.NullLiteral = Right (S.NullLiteral,Null)
    sequenceType value = demand (C.location value) (C.exprType value) >>= allTypes (\t -> case t of
      Sequence child -> Right child
      _ -> problem spanValue "SequenceType" "first/at require a Sequence, never an unordered Set")
    builtinType S.Count value = collection (C.location value) False (C.exprType value) >> pure (Primitive O.TNumber)
    builtinType S.Only value = collection (C.location value) False (C.exprType value)
    builtinType S.First value = optional <$> sequenceType value
    builtinType S.Entries value = demand (C.location value) (C.exprType value) >>= allTypes (\t -> case t of
      Map parameters result -> Right (Set (Record [("key",Record parameters),("value",result)]))
      _ -> problem spanValue "MapType" "entries requires a finite Map")
    matchArms _ (S.DefaultOnly fallback) = do
      checked <- expression signature environment fallback
      pure ([],Just checked)
    matchArms branches (S.NamedArms written fallback) = do
      let labels = [name | arm <- NE.toList written, let S.CaseArm name _ _ = S.syntax arm]
          declared = map fst branches
      unless (length labels == length (nub labels)) (problem spanValue "DuplicateBranch" "Duplicate match arm")
      unless (all (`elem` declared) labels) (problem spanValue "UnknownBranch" "Undeclared match arm")
      when (fallback == Nothing && sort labels /= sort declared) (problem spanValue "NonExhaustiveMatch" "Missing match arms")
      when (fallback /= Nothing && sort labels == sort declared) (problem spanValue "UnreachableFallback" "Fallback follows complete branch coverage")
      cases <- mapM (\arm -> do
        let S.CaseArm label binder body = S.syntax arm
        when (binder == "root") (problem (S.sourceSpan arm) "DuplicateBinding" "root is reserved")
        payload <- maybe (problem (S.sourceSpan arm) "UnknownBranch" label) Right (lookup label branches)
        result <- expression signature (M.insert binder payload environment) body
        pure (label,binder,result)) (NE.toList written)
      checkedFallback <- mapM (expression signature environment) fallback
      pure (cases,checkedFallback)

record :: C.Signature -> Environment -> S.SourceSpan -> [(String,S.Expr)] -> Either Diagnostic [(String,C.Expr)]
record signature environment spanValue fields = do
  let names = map fst fields
  unless (length names == length (nub names)) (problem spanValue "DuplicateOutput" "Repeated record/projection label")
  mapM (\(name,value) -> (,) name <$> expression signature environment value) fields

queryExpression :: C.Signature -> Environment -> S.SourceSpan -> S.Query -> Either Diagnostic (C.Query,Type)
queryExpression signature outer spanValue query = do
  (locals,sources) <- foldM source (M.empty,[]) (NE.toList (S.querySources query))
  (final,steps) <- foldM step (locals,[]) (S.querySteps query)
  projection <- case S.queryProjection query of
    S.Single value -> expression signature (final `M.union` outer) value
    S.NamedProjection fields -> do
      values <- record signature (final `M.union` outer) spanValue (NE.toList fields)
      pure (C.Expr spanValue (Record [(n,C.exprType v) | (n,v) <- values]) (C.Record values))
  let result = case S.querySelection query of S.AllResults -> Set (C.exprType projection); S.SingleResult -> C.exprType projection
  pure (C.Query (S.querySelection query) sources steps projection,result)
  where
    source (locals,sources) written = do
      let S.Source value name = S.syntax written
      fresh (S.sourceSpan written) locals name
      checked <- expression signature (locals `M.union` outer) value
      member <- collection (C.location checked) True (C.exprType checked)
      pure (M.insert name member locals,sources ++ [(name,checked)])
    step (locals,steps) written = case S.syntax written of
      S.Let binding -> do
        let S.Binding name value = S.syntax binding
        fresh (S.sourceSpan binding) locals name
        checked <- expression signature (locals `M.union` outer) value
        pure (M.insert name (C.exprType checked) locals,steps ++ [C.Let name checked])
      S.Where value -> do
        checked <- expression signature (locals `M.union` outer) value
        boolean checked
        pure (locals,steps ++ [C.Where checked])

