-- Finite, schema-level relation graph. No database rows or SQL names.
-- Value occurrences are distinguished by their semantic address, not by equality
-- of their payload and not by the identity of their enclosing population.
module Ontology.Center.Graph
  ( Address(..), population, within
  , KeyPart(..), Guard(..), Kind(..), Site(..)
  , Cardinality(..), Primitive(..), Edge(..)
  , World, world, addresses, sites, edges, siteAt, outgoingAt, incomingAt
  , Direction(..), Traversal(..), Relation, identity, forward, inverse, compose
  , relationSource, relationTarget, traversals, ownerRoute, incomingOwnerRoutes
  ) where

import Control.Monad (unless, when)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Ontology.Syntax (Name, NodeId)
import qualified Ontology.Syntax as O
import qualified Ontology.Relational as R

data Address = Address
  { addressPopulation :: Name
  , addressPath :: R.Path
  } deriving (Eq, Ord, Show)

population :: Name -> Address
population name = Address name []

within :: Address -> R.Path -> Address
within (Address name path) suffix = Address name (path ++ suffix)

-- Key components retain their declaring occurrence. Two nested collections
-- must not conflate their identically-spelled local occurrence components.
data KeyPart
  = PopulationKey Address R.KeyColumn
  | SetKey Address R.KeyColumn
  | ArgumentKey Address R.KeyColumn
  deriving (Eq, Show)

data Guard
  = Present Address
  | TagEquals Address Name
  deriving (Eq, Show)

data Kind
  = Atomic R.Atom
  | RecordValue
  | CollectionValue R.Distinctness
  | FunctionValue [Name]
  | AlternativeValue Name [Name]
  deriving (Eq, Show)

data Site = Site
  { siteAddress :: Address
  , siteKind :: Kind
  , siteKey :: [KeyPart]
  , siteGuards :: [Guard]
  , siteIdentity :: Maybe Name
  , siteMeaning :: R.Row
  } deriving (Eq, Show)

-- Bounds on data instances for this edge, not a count of schema nodes.
-- ExactlyOne for containment's inverse is conditional on the child existing.
data Cardinality = ExactlyOne | AtMostOne | Unbounded
  deriving (Eq, Ord, Show)

data Primitive
  = Field Name
  | Argument Name
  | Discriminant Name
  | Elements R.Distinctness
  | Entries [R.KeyColumn]
  | Variant Name Name
  | Reference Name
  deriving (Eq, Show)

data Edge = Edge
  { edgeSource :: Address
  , edgeTarget :: Address
  , edgePrimitive :: Primitive
  , edgeForward :: Cardinality
  , edgeBackward :: Cardinality
  , edgeGuards :: [Guard]
  } deriving (Eq, Show)

-- Construction is private: both endpoints and the single structural owner of
-- each non-root occurrence are validated before lazy unfolding can start.
data World = World
  { worldSites :: M.Map Address Site
  , worldEdges :: [Edge]
  , worldOutgoing :: M.Map Address [Edge]
  , worldIncoming :: M.Map Address [Edge]
  }

sites :: World -> [Site]
sites = M.elems . worldSites

addresses :: World -> [Address]
addresses = M.keys . worldSites

edges :: World -> [Edge]
edges = worldEdges

siteAt :: World -> Address -> Either String Site
siteAt graph address =
  maybe (Left ("Unknown center: " ++ show address)) Right
    (M.lookup address (worldSites graph))

outgoingAt, incomingAt :: World -> Address -> [Edge]
outgoingAt graph address = M.findWithDefault [] address (worldOutgoing graph)
incomingAt graph address = M.findWithDefault [] address (worldIncoming graph)

-- A finite composition of independently described occurrences.
data Fragment = Fragment [Site] [Edge]

combine :: [Fragment] -> Fragment
combine fragments = Fragment
  (concat [ns | Fragment ns _ <- fragments])
  (concat [es | Fragment _ es <- fragments])

data Place = Place Address [KeyPart] [Guard] (Maybe Name) Bool

placeAddress :: Place -> Address
placeAddress (Place address _ _ _ _) = address

attach :: Place -> Primitive -> Cardinality -> Place -> Fragment -> Fragment
attach parent primitive cardinal child (Fragment ns es) =
  Fragment ns (Edge (placeAddress parent) (placeAddress child) primitive
    cardinal ExactlyOne childGuards : es)
  where Place _ _ childGuards _ _ = child

lookupNode :: O.Ontology -> NodeId -> Either String O.Node
lookupNode ontology ident = maybe (Left ("Missing ontology node " ++ show ident)) Right
  (M.lookup ident (O.nodes ontology))

-- Input is the CHECKED ontology, not raw TypeScript or SQL. Using the ontology
-- here preserves ordinary field boundaries, including optional empty records
-- which have no columns in the current flattened relational representation.
world :: Name -> O.Ontology -> Either String World
world rootName ontology = do
  -- Guard even hand-built canonical inputs against non-productive value cycles.
  mapM_ (acyclic S.empty) (M.elems (O.namedNodes ontology))
  meaning <- R.relational rootName ontology
  fragments <- mapM (describePopulation meaning) (M.keys (R.populations meaning))
  let Fragment ns es = combine fragments
      index = M.fromList [(siteAddress n, n) | n <- ns]
      incoming = M.fromListWith (flip (++)) [(edgeTarget e, [e]) | e <- es]
  unless (length ns == M.size index) (Left "Duplicate semantic address")
  mapM_ (validEdge index) es
  mapM_ (validOwner incoming) ns
  pure (World index es
    (M.fromListWith (flip (++)) [(edgeSource e, [e]) | e <- es]) incoming)
  where
    acyclic seen ident = do
      when (S.member ident seen) (Left "Recursive by-value shape: use Ref")
      n <- lookupNode ontology ident
      let next = acyclic (S.insert ident seen)
      case n of
        O.Record fs -> mapM_ (next . O.fieldType) fs
        O.Many x -> next x
        O.Distinct _ x -> next x
        O.FunctionNode ps x -> mapM_ (next . O.parameterType) ps >> next x
        O.AlternativeNode _ bs -> mapM_ (next . O.branchType) bs
        O.Ref name -> unless (M.member name (O.namedNodes ontology))
          (Left ("Unknown reference target: " ++ name))
        _ -> pure ()
    describePopulation meaning' name = do
      ident <- maybe (Left ("Missing population: " ++ name)) Right
        (M.lookup name (O.namedNodes ontology))
      n <- lookupNode ontology ident
      case n of
        O.Record _ -> pure ()
        O.AlternativeNode _ _ -> pure ()
        _ -> Left ("Referenceable population must be a record or alternative: " ++ name)
      populationMeaning <-
        maybe (Left ("Missing relational population: " ++ name)) Right
          (M.lookup name (R.populations meaning'))
      let rootAddress = population name
          rootKey =
            map (PopulationKey rootAddress) (R.populationKey populationMeaning)
      describe ontology (Place rootAddress rootKey [] (Just name) False) ident
    validEdge index e = unless
      (M.member (edgeSource e) index && M.member (edgeTarget e) index)
      (Left ("Unresolved relation endpoint: " ++ show e))
    validOwner incoming s =
      let owners = filter (not . isReference) (M.findWithDefault [] (siteAddress s) incoming)
          expected = if null (addressPath (siteAddress s)) then 0 else 1
      in unless (length owners == expected) (Left "Ambiguous structural ownership")

-- These are schema descriptions, not updates to a partially constructed graph.
describe :: O.Ontology -> Place -> NodeId -> Either String Fragment
describe ontology place@(Place address key guards ident uniqueHere) nodeId = do
  shape <- lookupNode ontology nodeId
  meaning <- R.lowerNode ontology nodeId
  children <- case shape of
    O.Record fs -> mapM fieldPart fs
    O.Many child -> collectionParts R.DistinctWhole child
    O.Distinct selectors child -> collectionParts
      (if null selectors then R.DistinctWhole else R.DistinctBy selectors) child
    O.FunctionNode parameters result -> do
      argumentMeanings <- mapM (R.lowerNode ontology . O.parameterType) parameters
      unless (all keyMeaning argumentMeanings)
        (Left "Map parameters must have required scalar/reference leaves")
      let keys = [R.KeyColumn (R.Argument (O.parameterName p) : R.columnPath c) (R.columnAtom c)
                 | (p, r) <- zip parameters argumentMeanings, c <- R.columns r]
          entryAddress = within address [R.Entries]
          entry = Place entryAddress (key ++ map (ArgumentKey entryAddress) keys) guards Nothing False
      resultFragment <- describe ontology entry result
      argumentFragments <- mapM (argumentPart entry) parameters
      pure [attach place (Entries keys) Unbounded entry
        (combine (resultFragment : argumentFragments))]
    O.AlternativeNode tag branches -> do
      parts <- mapM (branchPart tag) branches
      let tagAddress = within address [R.TagName tag]
          atom = R.EnumAtom (map (O.TextLiteral . O.branchName) branches)
          tagMeaning = R.Row [R.Column [] atom []] [] []
          tagPlace = Place tagAddress key guards Nothing False
          tagPart = attach place (Discriminant tag) ExactlyOne tagPlace
            (Fragment [Site tagAddress (Atomic atom) key guards Nothing tagMeaning] [])
      pure (tagPart : parts)
    _ -> pure []
  let Fragment childSites childEdges = combine children
      references = case shape of
        O.Ref target -> [Edge address (population target) (Reference target)
          ExactlyOne (if uniqueHere then AtMostOne else Unbounded) guards]
        _ -> []
  pure (Fragment (Site address (kind shape) key guards ident meaning : childSites)
    (references ++ childEdges))
  where
    fieldPart f = do
      let target = within address [R.Field (O.fieldName f)]
          conditions = guards ++ [Present target | O.fieldOptional f]
          child = Place target key conditions Nothing (O.fieldUnique f)
          cardinal = if O.fieldOptional f then AtMostOne else ExactlyOne
      attach place (Field (O.fieldName f)) cardinal child <$> describe ontology child (O.fieldType f)
    collectionParts distinct childId = do
      memberMeaning <- R.lowerNode ontology childId
      let target = within address [R.Elements]
          memberKey =
            [ R.KeyColumn (R.columnPath column') (R.columnAtom column')
            | column' <- R.columns memberMeaning
            ]
          child =
            Place target
              (key ++ map (SetKey target) memberKey)
              guards Nothing False
      part <- describe ontology child childId
      pure [attach place (Elements distinct) Unbounded child part]
    argumentPart entry@(Place at keys conditions _ _) parameter = do
      let target = within at [R.Argument (O.parameterName parameter)]
          child = Place target keys conditions Nothing False
      attach entry (Argument (O.parameterName parameter)) ExactlyOne child
        <$> describe ontology child (O.parameterType parameter)
    branchPart tag branch = do
      let target = within address [R.Branch tag (O.branchName branch)]
          child = Place target key
            (guards ++ [TagEquals (within address [R.TagName tag]) (O.branchName branch)]) ident False
      attach place (Variant tag (O.branchName branch)) AtMostOne child
        <$> describe ontology child (O.branchType branch)
    keyMeaning r = null (R.dependents r) && null (R.rules r)
      && all (null . R.columnPresence) (R.columns r)

kind :: O.Node -> Kind
kind (O.Scalar p) = Atomic (R.ScalarAtom p)
kind (O.ScalarLiteral l) = Atomic (R.LiteralAtom l)
kind (O.ScalarEnum ls) = Atomic (R.EnumAtom ls)
kind (O.Ref name) = Atomic (R.ReferenceAtom name)
kind (O.Record _) = RecordValue
kind (O.Many _) = CollectionValue R.DistinctWhole
kind (O.Distinct [] _) = CollectionValue R.DistinctWhole
kind (O.Distinct ns _) = CollectionValue (R.DistinctBy ns)
kind (O.FunctionNode ps _) = FunctionValue (map O.parameterName ps)
kind (O.AlternativeNode tag bs) = AlternativeValue tag (map O.branchName bs)

isReference :: Edge -> Bool
isReference e = case edgePrimitive e of Reference _ -> True; _ -> False

-- Relations are endpoint-checked sequences, not SQL strings. Keeping the full
-- edge preserves scope, key parameters, cardinalities and tag/presence guards.
data Direction = Forward | Backward deriving (Eq, Show)
data Traversal = Traversal Direction Edge deriving (Eq, Show)
data Relation = Relation Address [Traversal] deriving (Eq, Show)

identity :: Address -> Relation
identity address = Relation address []

forward :: Edge -> Relation
forward e = Relation (edgeSource e) [Traversal Forward e]

relationSource :: Relation -> Address
relationSource (Relation address _) = address

relationTarget :: Relation -> Address
relationTarget (Relation address []) = address
relationTarget (Relation _ xs) = case last xs of
  Traversal Forward e -> edgeTarget e
  Traversal Backward e -> edgeSource e

traversals :: Relation -> [Traversal]
traversals (Relation _ xs) = xs

inverse :: Relation -> Relation
inverse r = Relation (relationTarget r) (map reverseStep (reverse (traversals r)))
  where
    reverseStep (Traversal Forward e) = Traversal Backward e
    reverseStep (Traversal Backward e) = Traversal Forward e

compose :: Relation -> Relation -> Either String Relation
compose left right
  | relationTarget left == relationSource right =
      Right (Relation (relationSource left) (traversals left ++ traversals right))
  | otherwise = Left "Cannot compose relations with different intermediate points"

-- Forward containment route from a population to an occurrence. References
-- are deliberately not traversed: canonical populations are new roots.
ownerRoute :: World -> Address -> Either String Relation
ownerRoute graph point = do
  _ <- siteAt graph point
  case filter (not . isReference) (incomingAt graph point) of
    [] -> Right (identity point)
    [e] -> do
      prefix <- ownerRoute graph (edgeSource e)
      compose prefix (forward e)
    _ -> Left "Ambiguous structural owner route"

-- Reverse each complete incoming path, not just its final field label.
-- These are candidate relationships; runtime row selection remains separate.
incomingOwnerRoutes :: World -> Address -> Either String [Relation]
incomingOwnerRoutes graph point = do
  _ <- siteAt graph point
  mapM route (incomingAt graph point)
  where
    route e = do
      prefix <- ownerRoute graph (edgeSource e)
      inverse <$> compose prefix (forward e)

