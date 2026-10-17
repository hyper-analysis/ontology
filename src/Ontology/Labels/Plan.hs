-- A finite description of possible JSON shapes, before SQL or rendering.
-- This checks labels for ALL values/branches a view can return, not one sample.
module Ontology.Labels.Plan
  ( Shape(..), Slot(..), labelShape, requirements, collisions, finiteValues
  
  ) where

import Control.Monad (when)
import Data.List (nub, tails)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Ontology.Center.Graph
import Ontology.Projection
import Ontology.Labels.Types
import Ontology.Labels.Adapter (localRelationship)
import qualified Ontology.Relational as R
import qualified Ontology.Syntax as O

data Shape
  = AtomicShape Address R.Atom
  | ObjectShape [Slot]
  | ArrayShape Shape
  | NullableShape Shape
  | FixedShape
  deriving (Eq, Show)

-- Only branches of THIS object are mutually exclusive. We never infer
-- exclusivity from equal schema addresses in two independently bound refs.
data Slot = Slot Property (Maybe String) Shape deriving (Eq, Show)

finiteValues :: R.Atom -> [O.Literal]
finiteValues (R.EnumAtom xs) = xs
finiteValues (R.LiteralAtom x) = [x]
finiteValues _ = []

primitiveOf :: Relation -> Maybe (Direction, Primitive)
primitiveOf r = case traversals r of
  [Traversal d e] -> Just (d, edgePrimitive e)
  _ -> Nothing

followed :: [ProjectedConnection] -> [(Relation, Projection)]
followed xs = [(r, p) | Followed r p <- xs]

labelShape :: World -> Projection -> Either String Shape
labelShape graph = describe
  where
    describe p = case projectedExpansion p of
      Stopped _ -> case projectedKind p of
        Atomic atom -> atomic S.empty (projectedAddress p) atom
        _ -> pure (ObjectShape [Slot (Structural (projectedAddress p) CutoffMarker) Nothing FixedShape])
      Expanded forwards backwards -> do
        let out = followed forwards
            incoming = followed backwards
            arguments = [(r,c) | (r,c) <- out, Just (Forward, Argument _) <- [primitiveOf r]]
            values = [(r,c) | (r,c) <- out, not (isArgument r)]
        payload <- contents p values incoming
        if null arguments then pure payload else do
          keys <- mapM (field Nothing) arguments
          pure (ObjectShape
            [ Slot (Structural (projectedAddress p) MapKey) Nothing (ObjectShape keys)
            , Slot (Structural (projectedAddress p) MapValue) Nothing payload ])
    isArgument r = case primitiveOf r of Just (Forward, Argument _) -> True; _ -> False
    isBranch r = case primitiveOf r of Just (Forward, Variant _ _) -> True; _ -> False
    field active (r,p) = do
      property <- localRelationship r (formFor r (projectedKind p))
      Slot property active <$> selected r p
    selected r p = do
      when (relationTarget r /= projectedAddress p) (Left "Label plan relation destination mismatch")
      result <- describe p
      pure $ case relationCardinality r of
        Unbounded -> ArrayShape result
        AtMostOne -> NullableShape result
        ExactlyOne -> result
    context _ value [] = pure value
    context at value rs = do
      slots <- mapM (field Nothing) rs
      pure (ObjectShape (Slot (Structural at ContextValue) Nothing value : slots))
    contents p out incoming = case projectedKind p of
      Atomic atom -> case [(r,c) | (r,c) <- out, Just (Forward, Reference _) <- [primitiveOf r]] of
        [(r,c)] -> selected r c >>= \v -> context at v incoming
        [] -> atomic S.empty at atom >>= \v -> context at v (out ++ incoming)
        _ -> Left "An atomic reference has several forward targets"
      RecordValue -> ObjectShape <$> mapM (field Nothing) (out ++ incoming)
      CollectionValue _ -> collection at out incoming
      FunctionValue _ -> collection at out incoming
      AlternativeValue _ _ -> do
        let ordinary = [(r,c) | (r,c) <- out, not (isBranch r)] ++ incoming
            branches = [(branch,(r,c)) | (r,c) <- out, Just (Forward, Variant _ branch) <- [primitiveOf r]]
        base <- mapM (field Nothing) ordinary
        variants <- mapM (\(branch,pair) -> field (Just branch) pair) branches
        pure (ObjectShape (base ++ variants))
      where at = projectedAddress p
    collection at [] incoming = context at (ObjectShape []) incoming
    collection at [(r,c)] incoming = selected r c >>= \v -> context at v incoming
    collection _ _ _ = Left "Collection has more than one membership relation"
    atomic seen at (R.ReferenceAtom target) = do
      when (S.member target seen) (Left ("Cyclic reference key in label requirements at " ++ addressText at))
      s <- siteAt graph (population target)
      let keys = [key k | k <- siteKey s]
      when (null keys) (Left ("Missing semantic reference key for " ++ target))
      keyObject (S.insert target seen) (population target) [(R.keyPath k,R.keyAtom k) | k <- keys]
      where
        key (PopulationKey _ k) = k
        key (ArgumentKey _ k) = k
        key (SetKey _ k) = k
    atomic _ at atom = pure (AtomicShape at atom)
    keyObject seen at [([],atom)] = atomic seen at atom
    keyObject seen at fields = do
      when (any (null . fst) fields) (Left "Scalar and object reference-key shapes overlap")
      let segments = nub [s | (s:_,_) <- fields]
      ObjectShape <$> mapM (oneKey seen at fields) segments
    oneKey seen at fields segment = case segment of
      R.Field _ -> child
      R.Argument _ -> child
      _ -> Left "Non-keyable segment in label requirements"
      where
        next = within at [segment]
        child = Slot (KeyField next Singular) Nothing
          <$> keyObject seen next [(rest,v) | (s:rest,v) <- fields, s == segment]

requirements :: Shape -> [Requirement]
requirements = M.elems . M.fromList . map (\r -> (requirementId r,r)) . collect
  where
    collect (AtomicShape at atom) =
      [Requirement (choiceId at v) ("Display value " ++ literalText v ++ " at " ++ addressText at)
      | v <- finiteValues atom]
    collect (ObjectShape slots) = concat
      [Requirement (propertyId property) ("Output property: " ++ propertyId property) : collect child
      | Slot property _ child <- slots]
    collect (ArrayShape s) = collect s
    collect (NullableShape s) = collect s
    collect FixedShape = []

collisions :: Labeling -> Shape -> [Diagnostic]
collisions labels = check "result"
  where
    check path (ObjectShape slots) = here ++ concat
      [check (path ++ " / " ++ propertyId property) child | Slot property _ child <- slots]
      where
        resolved = [(p,condition,n) | Slot p condition _ <- slots, Right n <- [nameOf labels p]]
        here = [Diagnostic Error "collision" path
                  ("Caption " ++ jsonString n ++ " can name both " ++ propertyId p ++ " and " ++ propertyId q) Nothing
               | (p,a,n):rest <- tails resolved, (q,b,m) <- rest, n == m, coexist a b]
    check path (ArrayShape s) = check (path ++ " []") s
    check path (NullableShape s) = check path s
    check _ _ = []
    coexist (Just a) (Just b) = a == b
    coexist _ _ = True

