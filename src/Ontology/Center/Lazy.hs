-- Potentially infinite CENTERED SCHEMA, never a stream of database rows.
-- No Eq/Show instance: recursive unfolding is observed explicitly instead.
module Ontology.Center.Lazy
  ( Centered(..), Connection(..), center ) where

import qualified Data.Map.Lazy as M
import Ontology.Center.Graph

data Centered = Centered
  { here :: Site
  , outgoing :: [Connection]
  , incoming :: [Connection]
  }

data Connection = Connection
  { via :: Relation
  , next :: Centered
  }

-- The finite map ties the knot. Its entries are non-strict: reference cycles
-- and containment/converse cycles do not expand until an observer demands them.
-- World's constructor is private, so all lookup endpoints were checked once.
center :: World -> Address -> Either String Centered
center graph point =
  maybe (Left ("Unknown center: " ++ show point)) Right (M.lookup point views)
  where
    views = M.fromList [(siteAddress s, unfold s) | s <- sites graph]
    unfold s = Centered s
      [ Connection (forward e) (views M.! edgeTarget e)
      | e <- outgoingAt graph (siteAddress s)
      ]
      [ Connection (inverse (forward e)) (views M.! edgeSource e)
      | e <- incomingAt graph (siteAddress s)
      ]

