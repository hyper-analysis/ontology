module Ontology.Relational
  ( Segment(..), Path, Atom(..), Presence(..), KeyColumn(..)
  , Distinctness(..), Boundary(..), Column(..), Rule(..)
  , Dependent(..), Row(..), Population(..), Relational(..)
  , lowerNode, lowerNamed, relational, relationalSummary
  ) where

import Data.List (intercalate)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Ontology.Syntax (Name, NodeId)
import qualified Ontology.Syntax as O

-- These paths are semantic names, never SQL identifiers.
data Segment
  = Field Name | Argument Name | TagName Name | Branch Name Name
  | Elements | Entries | Slot
  deriving (Eq, Ord, Show)
type Path = [Segment]
data Atom
  = ScalarAtom O.Primitive | LiteralAtom O.Literal | EnumAtom [O.Literal]
  | ReferenceAtom Name
  deriving (Eq, Show)
newtype Presence = PresentWhen Path deriving (Eq, Ord, Show)
data KeyColumn = KeyColumn
  { keyPath :: Path, keyAtom :: Atom } deriving (Eq, Show)
data Distinctness = DistinctWhole | DistinctBy [Name] deriving (Eq, Show)
data Boundary
  = CollectionBoundary Distinctness
  | FunctionBoundary
  | AlternativeBoundary { selectedTag :: Path, selectedBranch :: Name }
  deriving (Eq, Show)
data Column = Column
  { columnPath :: Path, columnAtom :: Atom, columnPresence :: [Presence] }
  deriving (Eq, Show)

-- OptionalValue is explicit: an optional empty record still has presence.
-- It cannot be recovered from a list of leaf-column nullabilities.
data Rule = UniqueValue Path | OptionalValue Path deriving (Eq, Show)
data Dependent = Dependent
  { dependentPath :: Path
  , boundary :: Boundary
  , addedKey :: [KeyColumn]
  , dependentPresence :: [Presence]
  , contents :: Row
  } deriving (Eq, Show)
data Row = Row
  { columns :: [Column], dependents :: [Dependent], rules :: [Rule] }
  deriving (Eq, Show)
data Population = Population
  { populationName :: Name, populationKey :: [KeyColumn], populationValue :: Row }
  deriving (Eq, Show)
data Relational = Relational
  { rootPopulations :: [(Name, Name)]
  , populations :: M.Map Name Population
  } deriving (Eq, Show)

emptyRow :: Row
emptyRow = Row [] [] []

together :: [Row] -> Row
together rs = Row (concatMap columns rs) (concatMap dependents rs) (concatMap rules rs)

prefixPresence :: Segment -> Presence -> Presence
prefixPresence s (PresentWhen p) = PresentWhen (s:p)

prefixBoundary :: Segment -> Boundary -> Boundary
prefixBoundary s (AlternativeBoundary p n) = AlternativeBoundary (s:p) n
prefixBoundary _ b = b

-- Naming a value renames its owner-relative interface, not dependent contents.
at :: Segment -> Row -> Row
at s row = Row
  [ c { columnPath = s : columnPath c
      , columnPresence = map (prefixPresence s) (columnPresence c) }
  | c <- columns row ]
  [ d { dependentPath = s : dependentPath d
      , boundary = prefixBoundary s (boundary d)
      , dependentPresence = map (prefixPresence s) (dependentPresence d) }
  | d <- dependents row ]
  [ case r of
      UniqueValue p -> UniqueValue (s:p)
      OptionalValue p -> OptionalValue (s:p)
  | r <- rules row ]

optional :: Row -> Row
optional row = row
  { columns = [c { columnPresence = PresentWhen [] : columnPresence c } | c <- columns row]
  , dependents = [d { dependentPresence = PresentWhen [] : dependentPresence d } | d <- dependents row]
  , rules = OptionalValue [] : rules row
  }

uniqueValue :: Row -> Row
uniqueValue row = row { rules = UniqueValue [] : rules row }

field :: Name -> Bool -> Bool -> Row -> Row
field name isOptional isUnique = at (Field name)
  . (if isOptional then optional else id)
  . (if isUnique then uniqueValue else id)

lookupNode :: O.Ontology -> NodeId -> Either String O.Node
lookupNode ontology ident = maybe (Left ("missing ontology node #" ++ show ident)) Right
  (M.lookup ident (O.nodes ontology))

lowerNode :: O.Ontology -> NodeId -> Either String Row
lowerNode ontology ident = do
  node <- lookupNode ontology ident
  case node of
    O.Scalar p -> pure (Row [Column [] (ScalarAtom p) []] [] [])
    O.ScalarLiteral x -> pure (Row [Column [] (LiteralAtom x) []] [] [])
    O.ScalarEnum xs -> pure (Row [Column [] (EnumAtom xs) []] [] [])
    O.Ref n -> pure (Row [Column [] (ReferenceAtom n) []] [] [])
    O.Record fs -> together <$> mapM lowerField fs
    O.Many child -> lowerSet ontology [] child
    O.Distinct selectors child -> lowerSet ontology selectors child
    O.FunctionNode ps result -> do
      key <- concat <$> mapM (lowerParameter ontology) ps
      value <- lowerNode ontology result
      pure (Row [] [Dependent [Entries] FunctionBoundary key [] value] [])
    O.AlternativeNode tag bs -> do
      branches <- mapM (lowerBranch tag) bs
      pure (Row [Column [TagName tag] (EnumAtom (map (O.TextLiteral . O.branchName) bs)) []]
        branches [])
  where
    lowerField f = field (O.fieldName f) (O.fieldOptional f) (O.fieldUnique f)
      <$> lowerNode ontology (O.fieldType f)
    lowerBranch tag b = Dependent [Branch tag (O.branchName b)]
      (AlternativeBoundary [TagName tag] (O.branchName b)) [] []
      <$> lowerNode ontology (O.branchType b)

keyColumns :: Path -> Row -> Either String [KeyColumn]
keyColumns prefix row
  | not (null (dependents row)) = Left "keyable value unexpectedly contains dependent relational structure"
  | any (not . null . columnPresence) (columns row)
      || any isOptional (rules row) = Left "keyable value unexpectedly contains optional fields"
  | otherwise = Right [KeyColumn (prefix ++ columnPath c) (columnAtom c) | c <- columns row]
  where
    isOptional (OptionalValue _) = True
    isOptional _ = False

lowerSet :: O.Ontology -> [Name] -> NodeId -> Either String Row
lowerSet ontology selectors child = do
  value <- lowerNode ontology child
  key <- keyColumns [] value
  let distinct = if null selectors then DistinctWhole else DistinctBy selectors
  pure (emptyRow { dependents = [Dependent [Elements] (CollectionBoundary distinct) key [] value] })

lowerParameter :: O.Ontology -> O.Parameter -> Either String [KeyColumn]
lowerParameter ontology p = do
  value <- lowerNode ontology (O.parameterType p)
  if not (null (dependents value)) || not (null (rules value))
    then Left ("map parameter " ++ O.parameterName p ++ " must have a rule-free keyable value")
    else keyColumns [Argument (O.parameterName p)] value

lowerNamed :: O.Ontology -> Name -> Either String Row
lowerNamed ontology name = do
  ident <- maybe (Left ("unknown ontology type " ++ name)) Right
    (M.lookup name (O.namedNodes ontology))
  lowerNode ontology ident

referencedEntities :: O.Ontology -> S.Set Name
referencedEntities ontology = S.fromList [n | O.Ref n <- M.elems (O.nodes ontology)]

rootPopulationNames :: Name -> O.Ontology -> Either String [(Name, Name)]
rootPopulationNames rootName ontology = do
  ident <- maybe (Left ("root type not found: " ++ rootName)) Right
    (M.lookup rootName (O.namedNodes ontology))
  root <- lookupNode ontology ident
  fs <- case root of
    O.Record xs -> Right xs
    _ -> Left "root ontology type must be an object"
  mapM populationFor fs
  where
    populationFor f = do
      wrapper <- lookupNode ontology (O.fieldType f)
      child <- case wrapper of
        O.Many x -> Right x
        O.Distinct _ x -> Right x
        _ -> Left ("root field " ++ O.fieldName f ++ " must be a collection")
      let names = [name | (name, candidate) <- M.toAscList (O.namedNodes ontology), candidate == child]
          referred = filter (`S.member` referencedEntities ontology) names
          candidates = if null referred then names else referred
      case candidates of
        [name] -> Right (O.fieldName f, name)
        [] -> Left ("root population " ++ O.fieldName f ++ " must contain a named type")
        ns -> Left ("root population " ++ O.fieldName f ++ " is ambiguous between " ++ show ns)

relational :: Name -> O.Ontology -> Either String Relational
relational root ontology = do
  roots <- rootPopulationNames root ontology
  let active = S.union (referencedEntities ontology) (S.fromList (map snd roots))
  values <- mapM meaning (S.toAscList active)
  pure (Relational roots (M.fromList [(populationName p, p) | p <- values]))
  where
    meaning name = Population name <$> declaredKey ontology name <*> lowerNamed ontology name

declaredKey :: O.Ontology -> Name -> Either String [KeyColumn]
declaredKey ontology name = do
  ident <- maybe (Left ("unknown ontology type " ++ name)) Right
    (M.lookup name (O.namedNodes ontology))
  node <- lookupNode ontology ident
  case node of
    O.Record fs -> concat <$> mapM lowerKey [f | f <- fs, O.fieldKey f]
    _ -> Left ("referenceable population " ++ name ++ " is not a keyed object")
  where
    lowerKey f = lowerNode ontology (O.fieldType f) >>= keyColumns [Field (O.fieldName f)]

renderSegment :: Segment -> String
renderSegment (Field n) = n
renderSegment (Argument n) = "(" ++ n ++ ")"
renderSegment (TagName n) = "<tag:" ++ n ++ ">"
renderSegment (Branch t n) = "<" ++ t ++ "=" ++ n ++ ">"
renderSegment Elements = "[]"
renderSegment Entries = "()"
renderSegment Slot = "#"

renderPath :: Path -> String
renderPath = intercalate "." . map renderSegment

renderRow :: String -> Row -> [String]
renderRow indent row =
  [indent ++ "column " ++ renderPath (columnPath c) ++ " :: " ++ show (columnAtom c)
    ++ (if null (columnPresence c) then "" else " guarded=" ++ show (columnPresence c))
  | c <- columns row]
  ++ [indent ++ "rule " ++ show r | r <- rules row]
  ++ concatMap (renderDependent indent) (dependents row)

renderDependent :: String -> Dependent -> [String]
renderDependent indent d =
  [indent ++ "dependent " ++ renderPath (dependentPath d) ++ "  " ++ show (boundary d)
  ,indent ++ "  +key " ++ intercalate ", "
    [renderPath (keyPath k) ++ " :: " ++ show (keyAtom k) | k <- addedKey d]]
  ++ renderRow (indent ++ "  ") (contents d)

relationalSummary :: Relational -> String
relationalSummary r = unlines
  (["Roots:"] ++ ["  " ++ f ++ " -> " ++ n | (f, n) <- rootPopulations r]
   ++ ["", "Populations:"]
   ++ concat [(n ++ " key=" ++ show (populationKey p) ++ " :") : renderRow "  " (populationValue p)
             | (n, p) <- M.toAscList (populations r)])

