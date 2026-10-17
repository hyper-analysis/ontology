-- One observation policy, not part of the meaning of centering.
-- Depth counts primitive relation edges in either direction. It does not limit
-- the number of runtime rows in a collection and does not execute any query.
module Ontology.Center.Observe
  ( Observation(..), Expansion(..), ObservedConnection(..), observeDepth
  , observationSize, renderObservation
  ) where

import Ontology.Center.Graph
import Ontology.Center.Lazy

data Observation = Observation
  { observedAddress :: Address
  , observedKind :: Kind
  , observedKey :: [KeyPart]
  , observedGuards :: [Guard]
  , expansion :: Expansion
  } deriving (Eq, Show)

data Expansion
  = Cutoff
  | Expanded [ObservedConnection] [ObservedConnection]
  deriving (Eq, Show)

data ObservedConnection = ObservedConnection Relation Observation
  deriving (Eq, Show)

observeDepth :: Int -> Centered -> Either String Observation
observeDepth depth value
  | depth < 0 = Left "Observation depth cannot be negative"
  | otherwise = Right (cut depth value)
  where
    cut n c = Observation
      (siteAddress (here c)) (siteKind (here c))
      (siteKey (here c)) (siteGuards (here c))
      (if n == 0 then Cutoff else
        Expanded (map (step (n - 1)) (outgoing c))
                 (map (step (n - 1)) (incoming c)))
    step n (Connection relation child) = ObservedConnection relation (cut n child)

observationSize :: Observation -> Int
observationSize value = 1 + case expansion value of
  Cutoff -> 0
  Expanded forwards backwards -> sum (map size (forwards ++ backwards))
  where size (ObservedConnection _ child) = observationSize child

-- Only a bounded observation is printable. Never traverses Centered directly.
renderObservation :: Observation -> String
renderObservation = unlines . render ""
  where
    render indent value =
      (indent ++ show (observedAddress value) ++ " : " ++ show (observedKind value)) :
      case expansion value of
        Cutoff -> [indent ++ "  [depth cutoff]"]
        Expanded forwards backwards ->
          concatMap (connection (indent ++ "  ") "out") forwards ++
          concatMap (connection (indent ++ "  ") "in") backwards
    connection indent direction (ObservedConnection relation child) =
      (indent ++ direction ++ " " ++ show (traversals relation)) : render (indent ++ "  ") child

