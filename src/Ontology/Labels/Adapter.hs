-- Adapter from projected/view relations to ontology-local label subjects.
-- The label map itself never names traversal routes or reference contexts.
module Ontology.Labels.Adapter
  ( localRelationship
  ) where

import Ontology.Center.Graph
import Ontology.Labels.Types

-- A projected relation may include reference and ownership plumbing. Its basic
-- label comes from the first authored ontology relation encountered from the
-- current semantic point. Direction is preserved; traversal history is not.
localRelationship :: Relation -> Form -> Either String Property
localRelationship relation form =
  case [Traversal d e | Traversal d e <- traversals relation, authored (edgePrimitive e)] of
    Traversal d e:_ ->
      Right (Relationship (if d == Forward then forward e else inverse (forward e)) form)
    [] ->
      Left ("Projected relation has no ontology-local label subject: " ++ relationId relation)
  where
    authored primitive = case primitive of
      Field _ -> True
      Argument _ -> True
      Discriminant _ -> True
      Variant _ _ -> True
      Reference _ -> False
      Elements _ -> False
      Entries _ -> False

