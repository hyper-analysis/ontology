-- Configurable finite observations, not an algorithm for choosing a good UI.
-- No SQL queries, database rows, LLM calls, or changes to centering semantics.
module Ontology.Projection
  ( Directions(..), References(..), Repetition(..), Match(..), EdgeSelection(..)
  , Projector(..), View(..), Projection(..), Expansion(..), ProjectedConnection(..)
  , StopReason(..), Omission(..), forwardValue, neighborhood, incomingContext
  , project, projectView, projectionSize, renderProjection
  ) where

import Data.Char (isSpace)
import qualified Data.Set as S
import Ontology.Center.Graph
import Ontology.Center.Lazy

data Directions = OutgoingOnly | IncomingOnly | Both
  deriving (Eq, Show)
data References = FollowReferences | ReferenceLinks
  deriving (Eq, Show)
data Repetition = AllowRepeats | StopAtRepeatedAddress
  deriving (Eq, Show)

-- Through matches any primitive in a connection; To matches its oriented
-- destination. To permits occurrence-specific choices, not just field names.
data Match = Through Primitive | To Address
  deriving (Eq, Show)
data EdgeSelection = AllEdges | OnlyEdges [Match] | ExceptEdges [Match]
  deriving (Eq, Show)

data Projector = Projector
  { maximumDepth :: Int
  , directions :: Directions
  , references :: References
  , repetition :: Repetition
  , edgeSelection :: EdgeSelection
  } deriving (Eq, Show)

data View = View
  { viewName :: String
  , viewCenter :: Address
  , viewProjector :: Projector
  } deriving (Eq, Show)

-- Metadata is retained for later query compilation; siteMeaning is deliberately
-- NOT copied wholesale, since it includes fields the projector may exclude.
data Projection = Projection
  { projectedAddress :: Address
  , projectedKind :: Kind
  , projectedKey :: [KeyPart]
  , projectedGuards :: [Guard]
  , projectedExpansion :: Expansion
  } deriving (Eq, Show)

data Expansion
  = Stopped StopReason
  | Expanded [ProjectedConnection] [ProjectedConnection]
  deriving (Eq, Show)
data ProjectedConnection
  = Followed Relation Projection
  | Omitted Relation Omission
  deriving (Eq, Show)
data StopReason = DepthLimit | RepeatedAddress
  deriving (Eq, Show)
data Omission = ReferenceBoundary | NotSelected
  deriving (Eq, Show)

-- Deliberately replaceable presets, not ontology laws.
forwardValue, neighborhood, incomingContext :: Int -> Projector
forwardValue depth =
  Projector depth OutgoingOnly ReferenceLinks AllowRepeats AllEdges
neighborhood depth =
  Projector depth Both FollowReferences StopAtRepeatedAddress AllEdges
incomingContext depth =
  (neighborhood depth) { directions = IncomingOnly }

-- Depth counts traversed connections in either direction. In the current
-- centered graph each connection is one primitive edge. The hard depth bound
-- remains even when repeated schema addresses are allowed.
project :: Projector -> Centered -> Either String Projection
project config value
  | maximumDepth config < 0 = Left "Projection depth cannot be negative"
  | otherwise = Right (cut S.empty (maximumDepth config) value)
  where
    cut seen depth c = Projection address (siteKind s) (siteKey s) (siteGuards s) result
      where
        s = here c
        address = siteAddress s
        nextSeen = S.insert address seen
        result
          | depth == 0 = Stopped DepthLimit
          | repetition config == StopAtRepeatedAddress && S.member address seen =
              Stopped RepeatedAddress
          | otherwise = Expanded
              (if directions config == IncomingOnly then []
               else map (step nextSeen (depth - 1)) (outgoing c))
              (if directions config == OutgoingOnly then []
               else map (step nextSeen (depth - 1)) (incoming c))
    step seen depth (Connection relation child)
      | not (selected (edgeSelection config) relation) = Omitted relation NotSelected
      | references config == ReferenceLinks && crossesReference relation =
          Omitted relation ReferenceBoundary
      | otherwise = Followed relation (cut seen depth child)

selected :: EdgeSelection -> Relation -> Bool
selected AllEdges _ = True
selected (OnlyEdges matches) relation = any (`matchesRelation` relation) matches
selected (ExceptEdges matches) relation = not (any (`matchesRelation` relation) matches)

matchesRelation :: Match -> Relation -> Bool
matchesRelation (To address) relation = relationTarget relation == address
matchesRelation (Through primitive) relation =
  any (\(Traversal _ edge) -> edgePrimitive edge == primitive) (traversals relation)

crossesReference :: Relation -> Bool
crossesReference relation = any referenceStep (traversals relation)
  where
    referenceStep (Traversal _ edge) = case edgePrimitive edge of
      Reference _ -> True
      _ -> False

projectView :: World -> View -> Either String Projection
projectView graph view
  | all isSpace (viewName view) = Left "View name must not be empty"
  | maximumDepth (viewProjector view) < 0 = Left "Projection depth cannot be negative"
  | otherwise = do
      mapM_ validateMatch matches
      focused <- center graph (viewCenter view)
      project (viewProjector view) focused
  where
    matches = case edgeSelection (viewProjector view) of
      AllEdges -> []
      OnlyEdges xs -> xs
      ExceptEdges xs -> xs
    validateMatch (To address) = () <$ siteAt graph address
    validateMatch (Through _) = Right ()

-- Only selected nodes count; omissions retain provenance but have no payload.
projectionSize :: Projection -> Int
projectionSize value = 1 + case projectedExpansion value of
  Stopped _ -> 0
  Expanded forwards backwards -> sum (map size (forwards ++ backwards))
  where
    size (Followed _ child) = projectionSize child
    size (Omitted _ _) = 0

renderProjection :: Projection -> String
renderProjection = unlines . render ""
  where
    render indent value =
      (indent ++ show (projectedAddress value) ++ " : " ++ show (projectedKind value)) :
      case projectedExpansion value of
        Stopped reason -> [indent ++ "  [" ++ show reason ++ "]"]
        Expanded forwards backwards ->
          concatMap (connection (indent ++ "  ") "out") forwards ++
          concatMap (connection (indent ++ "  ") "in") backwards
    label relation = show [(d, edgePrimitive e) | Traversal d e <- traversals relation]
    connection indent direction (Followed relation child) =
      (indent ++ direction ++ " " ++ label relation) : render (indent ++ "  ") child
    connection indent direction (Omitted relation reason) =
      [indent ++ direction ++ " " ++ label relation ++ " [" ++ show reason ++ "]"]

