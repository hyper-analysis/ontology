-- Labeling describes names, never row selection or storage identities.
module Ontology.Labels.Types
  ( Form(..), Wrapper(..), Property(..), Labeling(..)
  , Requirement(..), Diagnostic(..), Severity(..), Location(..), LabelReport(..)
  , propertyId, choiceId, titleId, relationId, addressText, literalText
  , relationLabel, technicalName, technical, formFor, relationCardinality
  , wrapperName, allWrappers, jsonString, reportJSON, renderReport
  ) where

import Data.Char (ord)
import Data.List (intercalate)
import Numeric (showHex)
import Ontology.Center.Graph
import qualified Ontology.Relational as R
import qualified Ontology.Syntax as O

data Form = Singular | Plural deriving (Eq, Ord, Show)
data Wrapper = MapKey | MapValue | ContextValue | CutoffMarker
  deriving (Eq, Ord, Show)

data Property
  = Relationship Relation Form
  | KeyField Address Form
  | Structural Address Wrapper
  deriving (Eq, Show)

-- Nothing at the public boundary selects technical. A supplied catalog must
-- be checked in full; a failed lookup is NOT an implicit technical fallback.
data Labeling = Labeling
  { nameOf :: Property -> Either String String
  , choicesAt :: Address -> Either String [(O.Literal, String)]
  }

data Location = Location FilePath Int Int deriving (Eq, Ord, Show)
data Severity = Error | Warning deriving (Eq, Ord, Show)
data Diagnostic = Diagnostic
  { diagnosticSeverity :: Severity
  , diagnosticCode :: String
  , diagnosticSubject :: String
  , diagnosticMessage :: String
  , diagnosticLocation :: Maybe Location
  } deriving (Eq, Ord, Show)

data Requirement = Requirement
  { requirementId :: String
  , requirementExplanation :: String
  } deriving (Eq, Ord, Show)

data LabelReport = LabelReport
  { labelRequirements :: [Requirement]
  , labelDiagnostics :: [Diagnostic]
  } deriving (Eq, Show)

formText :: Form -> String
formText Singular = "singular"
formText Plural = "plural"

wrapperName :: Wrapper -> String
wrapperName MapKey = "mapKey"
wrapperName MapValue = "mapValue"
wrapperName ContextValue = "contextValue"
wrapperName CutoffMarker = "cutoff"

allWrappers :: [Wrapper]
allWrappers = [MapKey, MapValue, ContextValue, CutoffMarker]

addressText :: Address -> String
addressText (Address pop path) = pop ++ concatMap segment path
  where
    segment (R.Field n) = "." ++ n
    segment (R.Argument n) = ".(" ++ n ++ ")"
    segment (R.TagName n) = ".#" ++ n
    segment (R.Branch t n) = ".[" ++ t ++ "=" ++ n ++ "]"
    segment R.Elements = "[]"
    segment R.Entries = "()"
    segment R.Slot = "#"

primitiveLabel :: Primitive -> String
primitiveLabel (Field n) = n
primitiveLabel (Argument n) = n
primitiveLabel (Discriminant n) = n
primitiveLabel (Variant _ n) = n
primitiveLabel (Reference _) = "value"
primitiveLabel (Elements _) = "items"
primitiveLabel (Entries _) = "entries"

-- Existing technical output spelling. It is NOT the identity of a caption.
relationLabel :: Relation -> String
relationLabel r = intercalate "/" (map label (traversals r))
  where
    label (Traversal Forward e) = primitiveLabel (edgePrimitive e)
    label (Traversal Backward e) = "^" ++ case edgePrimitive e of
      Reference _ -> addressText (edgeSource e)
      p -> primitiveLabel p

-- A route identifier includes every oriented endpoint. Two equal-looking
-- paths, or two different references to the same population, cannot alias.
relationId :: Relation -> String
relationId r = addressText (relationSource r) ++ " :: " ++ intercalate "; "
  [ (if d == Forward then "+" else "-") ++ addressText (edgeSource e)
      ++ " > " ++ addressText (edgeTarget e) ++ " : " ++ primitiveLabel (edgePrimitive e)
  | Traversal d e <- traversals r ]

propertyId :: Property -> String
propertyId (KeyField at form) = "name " ++ addressText at ++ " " ++ formText form
propertyId (Structural _ w) = "wrapper " ++ wrapperName w
propertyId (Relationship r form) = subject ++ " " ++ formText form
  where
    subject = case traversals r of
      [Traversal d e] -> case edgePrimitive e of
        Reference _ -> (if d == Forward then "reference " else "inverse-reference ")
          ++ addressText (edgeSource e)
        _ -> (if d == Forward then "name " else "inverse ") ++ addressText (edgeTarget e)
      _ -> "route " ++ relationId r

titleId :: Address -> Form -> String
titleId at form = "title " ++ addressText at ++ " " ++ formText form

literalText :: O.Literal -> String
literalText (O.TextLiteral s) = jsonString s
literalText (O.NumberLiteral n) = show n
literalText (O.BooleanLiteral b) = if b then "true" else "false"

choiceId :: Address -> O.Literal -> String
choiceId at value = "choice " ++ addressText at ++ " " ++ literalText value

technicalName :: Property -> Either String String
technicalName (Relationship r _) = Right (relationLabel r)
technicalName (Structural _ MapKey) = Right "key"
technicalName (Structural _ MapValue) = Right "value"
technicalName (Structural _ ContextValue) = Right "value"
technicalName (Structural _ CutoffMarker) = Right "$cutoff"
technicalName (KeyField at _) = case reverse (addressPath at) of
  R.Field n:_ -> Right n
  R.Argument n:_ -> Right n
  _ -> Left ("Not a key-field location: " ++ addressText at)

technical :: Labeling
technical = Labeling technicalName (const (Right []))

relationCardinality :: Relation -> Cardinality
relationCardinality = foldr (max . one) ExactlyOne . traversals
  where
    one (Traversal Forward e) = edgeForward e
    one (Traversal Backward e) = edgeBackward e

-- A collection heading names the members, not the single container. This is
-- an explicit v1 convention, never a guess based on a runtime row count.
formFor :: Relation -> Kind -> Form
formFor r kind
  | relationCardinality r == Unbounded = Plural
  | otherwise = case kind of
      CollectionValue _ -> Plural
      FunctionValue _ -> Plural
      _ -> Singular

jsonString :: String -> String
jsonString s = "\"" ++ concatMap escape s ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape c | ord c < 32 = let hex = showHex (ord c) "" in "\\u" ++ replicate (4 - length hex) '0' ++ hex
             | otherwise = [c]

reportJSON :: LabelReport -> String
reportJSON report = "{\"complete\":" ++ bool (not (any isError ds))
  ++ ",\"requirements\":[" ++ intercalate "," (map requirement (labelRequirements report))
  ++ "],\"diagnostics\":[" ++ intercalate "," (map diagnostic ds) ++ "]}"
  where
    ds = labelDiagnostics report
    isError = (== Error) . diagnosticSeverity
    bool True = "true"
    bool False = "false"
    requirement r = "{\"id\":" ++ jsonString (requirementId r)
      ++ ",\"explanation\":" ++ jsonString (requirementExplanation r) ++ "}"
    diagnostic d = "{\"severity\":" ++ jsonString (if isError d then "error" else "warning")
      ++ ",\"code\":" ++ jsonString (diagnosticCode d)
      ++ ",\"subject\":" ++ jsonString (diagnosticSubject d)
      ++ ",\"message\":" ++ jsonString (diagnosticMessage d)
      ++ ",\"location\":" ++ location (diagnosticLocation d) ++ "}"
    location Nothing = "null"
    location (Just (Location file line col)) = "{\"file\":" ++ jsonString file
      ++ ",\"line\":" ++ show line ++ ",\"column\":" ++ show col ++ "}"

renderReport :: LabelReport -> String
renderReport report = unlines
  ((show (length (labelRequirements report)) ++ " required labels; "
    ++ show (length [() | d <- labelDiagnostics report, diagnosticSeverity d == Error]) ++ " errors")
  : [show (diagnosticSeverity d) ++ " [" ++ diagnosticCode d ++ "] "
      ++ diagnosticSubject d ++ ": " ++ diagnosticMessage d
      ++ maybe "" (\(Location f l c) -> " (" ++ f ++ ":" ++ show l ++ ":" ++ show c ++ ")") (diagnosticLocation d)
    | d <- labelDiagnostics report])

