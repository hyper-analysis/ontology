-- A restricted JSX backend. User strings are always expression literals;
-- tags/attributes are closed constructors. There is no raw HTML or raw JS node.
module Application.JSX
  ( JSX(..), Tag(..), Attribute(..), lower, renderJSX, jsString, literalJS
  , expressionJS, testJS
  ) where

import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Application.Presentation
import Ontology.Labels.Types (propertyId)
import qualified Ontology.Syntax as O

data Tag = Main | Heading | DefinitionList | Division | Term | Definition
  | Paragraph | Span deriving (Eq, Show)
data Attribute = Observation String | Semantic String deriving (Eq, Show)
data JSX
  = Element Tag [Attribute] [JSX]
  | TextNode String
  | ScalarNode Expr Printer
  | ConditionalNode Test JSX JSX
  | EachNode Expr Int JSX
  | Fragment [JSX]
  deriving (Eq, Show)

lower :: Presentation -> JSX
lower (Display _ expression printer) = Element Span [Observation "value"] [ScalarNode expression printer]
lower (Group sections) = Element DefinitionList [] (map section sections)
  where
    section (Section caption subject guard body) =
      let node = Element Division [Semantic (propertyId subject)]
            [Element Term [Observation "caption"] [TextNode caption], Element Definition [] [lower body]]
      in maybe node (\predicate -> ConditionalNode predicate node (Fragment [])) guard
lower (Repeat expression binder body) = EachNode expression binder (lower body)
lower (Conditional predicate yes no) = ConditionalNode predicate (lower yes) (lower no)
lower (Message text) = Element Paragraph [Observation "message"] [TextNode text]

jsonText :: A.ToJSON a => a -> String
jsonText = T.unpack . T.decodeUtf8 . B.toStrict . A.encode

jsString :: String -> String
jsString = concatMap protect . jsonText
  where
    protect '<' = "\\u003c"
    protect '\x2028' = "\\u2028"
    protect '\x2029' = "\\u2029"
    protect c = [c]

literalJS :: O.Literal -> String
literalJS (O.TextLiteral s) = jsString s
literalJS (O.NumberLiteral n) = jsonText n
literalJS (O.BooleanLiteral b) = if b then "true" else "false"

expressionJS :: Expr -> String
expressionJS Input = "data"
expressionJS (Item n) = "item" ++ show n
expressionJS (Get source key) = "(" ++ expressionJS source ++ ")[" ++ jsString key ++ "]"

testJS :: Test -> String
testJS (IsNull expression) = expressionJS expression ++ " === null"
testJS (IsEmpty expression) = expressionJS expression ++ ".length === 0"
testJS (Has expression key) = expressionJS (Get expression key) ++ " !== undefined"

printerJS :: Expr -> Printer -> String
printerJS expression Verbatim = "String(" ++ expressionJS expression ++ ")"
printerJS expression (Finite entries) = foldr branch (printerJS expression Verbatim) entries
  where branch (value,caption) rest = "(" ++ expressionJS expression ++ " === " ++ literalJS value
          ++ " ? " ++ jsString caption ++ " : " ++ rest ++ ")"

tagName :: Tag -> String
tagName Main = "main"
tagName Heading = "h1"
tagName DefinitionList = "dl"
tagName Division = "div"
tagName Term = "dt"
tagName Definition = "dd"
tagName Paragraph = "p"
tagName Span = "span"

attribute :: Attribute -> String
attribute (Observation role) = " data-observation={" ++ jsString role ++ "}"
attribute (Semantic subject) = " data-semantic={" ++ jsString subject ++ "}"

renderJSX :: JSX -> String
renderJSX (Element tag attributes children) = "<" ++ tagName tag
  ++ concatMap attribute attributes ++ ">\n" ++ concatMap ((++ "\n") . renderJSX) children
  ++ "</" ++ tagName tag ++ ">"
renderJSX (TextNode text) = "{" ++ jsString text ++ "}"
renderJSX (ScalarNode expression printer) = "{" ++ printerJS expression printer ++ "}"
renderJSX (ConditionalNode predicate yes no) = "<>{" ++ testJS predicate
  ++ " ? (" ++ renderJSX yes ++ ") : (" ++ renderJSX no ++ ")}</>"
renderJSX (EachNode expression binder child) = "<ul>{" ++ expressionJS expression
  ++ ".map((item" ++ show binder ++ ", index" ++ show binder ++ ") => ("
  ++ "<li key={index" ++ show binder ++ "}>" ++ renderJSX child ++ "</li>))}</ul>"
renderJSX (Fragment children) = "<>" ++ concatMap renderJSX children ++ "</>"

