-- Frontend correspondence, independent of Labels.Plan and PostgreSQL lowering.
-- Technical output keys and semantic label subjects remain distinct.
module Application.Data
  ( PageData(..), DataField(..), Presence(..), Scalar(..)
  , pageData, nullable, finiteValues
  ) where

import Control.Monad (unless, when)
import Data.List (nub, tails)
import qualified Data.Set as S
import Ontology.Center.Graph
import Ontology.Projection
import Ontology.Views (PreparedView(..), keyPart)
import Ontology.Labels.Types (Form(..), Property(..), Wrapper(..), Labeling(..), technical, formFor, relationCardinality)
import qualified Ontology.Relational as R
import qualified Ontology.Syntax as O

data Scalar = SemanticScalar Address R.Atom | FixedText String deriving (Eq, Show)
data PageData = ScalarData Scalar | ObjectData [DataField]
  | ArrayData PageData | NullableData PageData deriving (Eq, Show)
data Presence = Required | BranchOnly String deriving (Eq, Show)
data DataField = DataField
  { dataKey :: String, dataSubject :: Property
  , dataPresence :: Presence, dataShape :: PageData
  } deriving (Eq, Show)

nullable :: PageData -> PageData
nullable s@NullableData{} = s
nullable s = NullableData s

finiteValues :: R.Atom -> [O.Literal]
finiteValues (R.EnumAtom values) = values
finiteValues (R.LiteralAtom value) = [value]
finiteValues _ = []

-- The outer read wrapper returns JSON null when no center is found.
pageData :: World -> PreparedView -> Either String PageData
pageData graph view = do
  unless (preparedCenter view == projectedAddress (preparedProjection view))
    (Left "View and projection have different centers")
  nullable <$> describe (preparedProjection view)
  where
    describe p = case projectedExpansion p of
      Stopped reason -> case projectedKind p of
        Atomic atom -> atomic S.empty (projectedAddress p) atom
        _ -> wrapper (projectedAddress p) CutoffMarker (ScalarData (FixedText (show reason))) >>= object . (:[])
      Expanded forwards backwards -> do
        let out = followed forwards
            incoming = followed backwards
            arguments = filter (isArgument . fst) out
            values = filter (not . isArgument . fst) out
        body <- contents p values incoming
        if null arguments then pure body else do
          keys <- mapM (field Required) arguments >>= object
          keyField <- wrapper (projectedAddress p) MapKey keys
          valueField <- wrapper (projectedAddress p) MapValue body
          object [keyField, valueField]
    field presence (relation, child) = do
      let subject = Relationship relation (formFor relation (projectedKind child))
      name <- nameOf technical subject
      shape <- selected relation child
      pure (DataField name subject presence shape)
    selected relation child = do
      unless (relationTarget relation == projectedAddress child)
        (Left "Page data relation destination mismatch")
      shape <- describe child
      pure $ case relationCardinality relation of
        ExactlyOne -> shape
        AtMostOne -> nullable shape
        Unbounded -> ArrayData shape
    contents p out incoming = case projectedKind p of
      Atomic atom -> case [(r,c) | (r,c) <- out, Just (Forward, Reference _) <- [primitiveOf r]] of
        [(relation,child)] -> selected relation child >>= \s -> context at s incoming
        [] -> atomic S.empty at atom >>= \s -> context at s (out ++ incoming)
        _ -> Left "Reference projection has several forward targets"
      RecordValue -> mapM (field Required) (out ++ incoming) >>= object
      CollectionValue _ -> collection at out incoming
      FunctionValue _ -> collection at out incoming
      AlternativeValue _ _ -> do
        base <- mapM (field Required) (filter (not . isBranch . fst) out ++ incoming)
        variants <- mapM (\(branch,pair) -> field (BranchOnly branch) pair)
          [(branch,(r,c)) | (r,c) <- out, Just (Forward, Variant _ branch) <- [primitiveOf r]]
        object (base ++ variants)
      where at = projectedAddress p
    collection at [] incoming = context at (ObjectData []) incoming
    collection at [(r,c)] incoming = selected r c >>= \s -> context at s incoming
    collection _ _ _ = Left "Collection projection has several membership relations"
    context _ value [] = Right value
    context at value relations = do
      self <- wrapper at ContextValue value
      rest <- mapM (field Required) relations
      object (self:rest)
    wrapper at role value = do
      let subject = Structural at role
      name <- nameOf technical subject
      pure (DataField name subject Required value)
    atomic seen _ (R.ReferenceAtom target) = do
      when (S.member target seen) (Left "Cyclic semantic reference key in page data")
      site <- siteAt graph (population target)
      let keys = map keyPart (siteKey site)
      when (null keys) (Left ("Missing semantic reference key for " ++ target))
      keyObject (S.insert target seen) (population target)
        [(R.keyPath key,R.keyAtom key) | key <- keys]
    atomic _ at atom = Right (ScalarData (SemanticScalar at atom))
    keyObject seen at [([],atom)] = atomic seen at atom
    keyObject seen at fields = do
      when (any (null . fst) fields) (Left "Overlapping scalar and object reference keys")
      let segments = nub [s | (s:_,_) <- fields]
      mapM (oneKey seen at fields) segments >>= object
    oneKey seen at fields segment = do
      case segment of
        R.Field _ -> pure ()
        R.Argument _ -> pure ()
        _ -> Left "Non-keyable segment in page data"
      let next = within at [segment]
          subject = KeyField next Singular
      name <- nameOf technical subject
      child <- keyObject seen next [(rest,a) | (s:rest,a) <- fields, s == segment]
      pure (DataField name subject Required child)

-- Exclusivity is local to this object, never to another reference occurrence.
object :: [DataField] -> Either String PageData
object fields = do
  unless (null [(a,b) | a:rest <- tails fields, b <- rest
    , dataKey a == dataKey b, coexist (dataPresence a) (dataPresence b)])
    (Left "Coexisting technical JSON keys collide in page data")
  pure (ObjectData fields)
  where
    coexist (BranchOnly a) (BranchOnly b) = a == b
    coexist _ _ = True

followed :: [ProjectedConnection] -> [(Relation, Projection)]
followed connections = [(r,p) | Followed r p <- connections]
primitiveOf :: Relation -> Maybe (Direction, Primitive)
primitiveOf r = case traversals r of
  [Traversal direction edge] -> Just (direction, edgePrimitive edge)
  _ -> Nothing
isArgument, isBranch :: Relation -> Bool
isArgument r = case primitiveOf r of Just (Forward, Argument _) -> True; _ -> False
isBranch r = case primitiveOf r of Just (Forward, Variant _ _) -> True; _ -> False

