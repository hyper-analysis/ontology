-- Presentation semantics are Haskell values, not TypeScript layout heuristics.
module Application.Presentation
  ( Expr(..), Test(..), Printer(..), Presentation(..), Section(..)
  , presentation, interpret, eval, test, printScalar
  ) where

import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as B
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Vector as V
import Application.Data
import Ontology.Labels.Types (Labeling(..), Property)
import qualified Ontology.Syntax as O

-- Item is a lexical binder, not a database identity or mutable cursor.
data Expr = Input | Item Int | Get Expr String deriving (Eq, Show)
data Test = IsNull Expr | IsEmpty Expr | Has Expr String deriving (Eq, Show)
data Printer = Verbatim | Finite [(O.Literal, String)] deriving (Eq, Show)
data Presentation
  = Display Scalar Expr Printer
  | Group [Section]
  | Repeat Expr Int Presentation
  | Conditional Test Presentation Presentation
  | Message String
  deriving (Eq, Show)
data Section = Section
  { sectionCaption :: String
  , sectionSubject :: Property
  , sectionWhen :: Maybe Test
  , sectionBody :: Presentation
  } deriving (Eq, Show)

-- A fixed, replaceable v1 convention: nested labeled groups and lists. No
-- fetching, layout optimization, raw HTML, inferred links, or hidden data.
presentation :: Labeling -> PageData -> Either String Presentation
presentation labels = describe 0 Input
  where
    describe depth expression shape = case shape of
      ScalarData scalar -> do
        printer <- case scalar of
          SemanticScalar at _ -> do
            values <- choicesAt labels at
            pure (if null values then Verbatim else Finite values)
          FixedText _ -> pure Verbatim
        pure (Display scalar expression printer)
      ObjectData [] -> pure (Message "No selected fields")
      ObjectData fields -> Group <$> mapM (section depth expression) fields
      ArrayData child -> do
        body <- describe (depth + 1) (Item depth) child
        pure (Conditional (IsEmpty expression) (Message "No entries")
          (Repeat expression depth body))
      NullableData child -> Conditional (IsNull expression) (Message "No value")
        <$> describe depth expression child
    section depth expression field = do
      caption <- nameOf labels (dataSubject field)
      child <- describe depth (Get expression (dataKey field)) (dataShape field)
      let guard = case dataPresence field of
            Required -> Nothing
            BranchOnly _ -> Just (Has expression (dataKey field))
      pure (Section caption (dataSubject field) guard child)

-- Reference interpreter. Produces the ordered text observations corresponding
-- to caption/value/message nodes. React output is compared with these in CI.
-- It uses actual JSON, but does not inspect JSX or generated JavaScript.
type Environment = M.Map Int A.Value

eval :: A.Value -> Environment -> Expr -> Either String A.Value
eval input _ Input = Right input
eval _ environment (Item binder) =
  maybe (Left "Unbound presentation item") Right (M.lookup binder environment)
eval input environment (Get source key) = do
  value <- eval input environment source
  case value of
    A.Object fields -> maybe (Left ("Missing input property " ++ key)) Right
      (KM.lookup (K.fromString key) fields)
    _ -> Left ("Property access on a non-object: " ++ key)

test :: A.Value -> Environment -> Test -> Either String Bool
test input environment condition = case condition of
  IsNull expression -> (== A.Null) <$> eval input environment expression
  IsEmpty expression -> do
    value <- eval input environment expression
    case value of A.Array xs -> Right (V.null xs); _ -> Left "Empty test requires an array"
  Has expression key -> do
    value <- eval input environment expression
    case value of A.Object fields -> Right (KM.member (K.fromString key) fields)
                  _ -> Left "Presence test requires an object"

literalValue :: O.Literal -> A.Value
literalValue (O.TextLiteral x) = A.String (T.pack x)
literalValue (O.NumberLiteral x) = A.Number x
literalValue (O.BooleanLiteral x) = A.Bool x

printScalar :: Printer -> A.Value -> Either String String
printScalar (Finite entries) value = case [caption | (literal,caption) <- entries, literalValue literal == value] of
  [caption] -> Right caption
  [] -> Left "Value outside the declared finite display domain"
  _ -> Left "Ambiguous finite display domain"
printScalar Verbatim (A.String value) = Right (T.unpack value)
printScalar Verbatim value@A.Number{} = Right (B.unpack (A.encode value))
printScalar Verbatim (A.Bool True) = Right "true"
printScalar Verbatim (A.Bool False) = Right "false"
printScalar Verbatim _ = Left "Display expects a non-null scalar"

interpret :: Presentation -> A.Value -> Either String [String]
interpret tree input = observe M.empty tree
  where
    observe environment p = case p of
      Display _ expression printer -> do
        value <- eval input environment expression
        (:[]) <$> printScalar printer value
      Group sections -> concat <$> mapM (oneSection environment) sections
      Repeat expression binder body -> do
        value <- eval input environment expression
        case value of
          A.Array xs -> concat <$> mapM (\x -> observe (M.insert binder x environment) body) (V.toList xs)
          _ -> Left "Repetition expects an array"
      Conditional predicate yes no -> do
        choose <- test input environment predicate
        observe environment (if choose then yes else no)
      Message text -> pure [text]
    oneSection environment (Section caption _ guard body) = do
      visible <- maybe (Right True) (test input environment) guard
      if visible then (caption :) <$> observe environment body else pure []

