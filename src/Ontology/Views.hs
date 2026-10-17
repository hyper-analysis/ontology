module Ontology.Views
  ( CenterStep(..), ViewSource(..), Parameter(..), PreparedView(..)
  , prepareView, keyParameters, keyPart, keyOwner
  ) where

import Control.Monad (unless, when)
import Data.Char (isSpace)
import qualified Data.Set as S
import Ontology.Center.Graph
import Ontology.Center.Lazy (center)
import Ontology.Projection
import qualified Ontology.Relational as R

data CenterStep
  = CenterField String
  | CenterBranch Int
  | CenterEntries
  | CenterElements
  | CenterArgument String
  | CenterTag
  deriving (Eq, Show)

data ViewSource = ViewSource
  { sourceViewName :: String
  , sourcePopulation :: String
  , sourceCenter :: [CenterStep]
  , sourceProjector :: Projector
  } deriving (Eq, Show)

-- Origin is semantic, never a generated table/column. Each reference hop says
-- which target population's key field supplies the next component. The final
-- atom is scalar: an internal PostgreSQL surrogate is never an API argument.
data Parameter = Parameter
  { parameterName :: String
  , parameterAtom :: R.Atom
  , parameterOrigin :: KeyPart
  , parameterReferences :: [(String, R.Path)]
  } deriving (Eq, Show)

data PreparedView = PreparedView
  { preparedName :: String
  , preparedPopulation :: String
  , preparedCenter :: Address
  , preparedParameters :: [Parameter]
  , preparedProjection :: Projection
  } deriving (Eq, Show)

keyPart :: KeyPart -> R.KeyColumn
keyPart (PopulationKey _ k) = k
keyPart (ArgumentKey _ k) = k
keyPart (SetKey _ k) = k

keyOwner :: KeyPart -> Address
keyOwner (PopulationKey a _) = a
keyOwner (ArgumentKey a _) = a
keyOwner (SetKey a _) = a

-- Finite product expansion. This describes parameters; it reads no data.
-- keys(Ref T) = keys(T); keys(atomic) = [atomic].
-- Cycles in identity definitions are rejected, not cut at an arbitrary depth.
keyParameters
  :: (String -> Either String [R.KeyColumn])
  -> [KeyPart]
  -> Either String [Parameter]
keyParameters populationKeys parts = do
  leaves <- fmap concat (mapM expandPart (zip [1 :: Int ..] parts))
  unless (length leaves == S.size (S.fromList (map parameterName leaves)))
    (Left "Colliding semantic parameter names")
  pure leaves
  where
    expandPart (index, origin) =
      expand S.empty origin []
        (role origin ++ "_" ++ show index ++ "_" ++ pathName (R.keyPath (keyPart origin)))
        (R.keyAtom (keyPart origin))
    expand seen origin route name (R.ReferenceAtom target) = do
      when (S.member target seen)
        (Left ("Cyclic reference-based semantic key at " ++ target))
      keys <- populationKeys target
      when (null keys) (Left ("Reference target has no finite semantic key: " ++ target))
      fmap concat $ mapM
        (\k -> expand (S.insert target seen) origin
          (route ++ [(target, R.keyPath k)])
          (name ++ "__" ++ pathName (R.keyPath k)) (R.keyAtom k)) keys
    expand _ origin route name atom =
      Right [Parameter name atom origin route]
    role (PopulationKey _ _) = "root"
    role (ArgumentKey _ _) = "arg"
    role (SetKey _ _) = "member"

pathName :: R.Path -> String
pathName [] = "value"
pathName xs = concatMap part xs
  where
    part (R.Field n) = "_" ++ n
    part (R.Argument n) = "_" ++ n
    part (R.TagName n) = "_" ++ n
    part (R.Branch t n) = "_" ++ t ++ "_" ++ n
    part R.Elements = "_item"
    part R.Entries = "_entry"
    part R.Slot = "_slot"

prepareView :: World -> ViewSource -> Either String PreparedView
prepareView graph source = do
  when (all isSpace (sourceViewName source)) (Left "View name must not be empty")
  let root = population (sourcePopulation source)
  _ <- siteAt graph root
  address <- resolveCenter graph root (sourceCenter source)
  s <- siteAt graph address
  p <- center graph address >>= project (sourceProjector source)
  parameters <- keyParameters (fmap (map keyPart . siteKey) . siteAt graph . population) (siteKey s)
  pure (PreparedView (sourceViewName source) (sourcePopulation source) address parameters p)

resolveCenter :: World -> Address -> [CenterStep] -> Either String Address
resolveCenter _ address [] = Right address
resolveCenter graph address (step:rest) = do
  next <- case step of
    CenterField name -> matching (== Field name)
    CenterArgument name -> matching (== Argument name)
    CenterEntries -> matching (\p -> case p of Entries _ -> True; _ -> False)
    CenterElements -> matching (\p -> case p of Elements _ -> True; _ -> False)
    CenterTag -> matching (\p -> case p of Discriminant _ -> True; _ -> False)
    CenterBranch index -> do
      s <- siteAt graph address
      case siteKind s of
        AlternativeValue tag names
          | index >= 0 && index < length names -> matching (== Variant tag (names !! index))
        _ -> Left ("Alternative branch index out of range at " ++ show address)
  resolveCenter graph next rest
  where
    matching predicate = case
      [edgeTarget e | e <- outgoingAt graph address, predicate (edgePrimitive e)] of
        [target] -> Right target
        [] -> Left ("Center step not found at " ++ show address ++ ": " ++ show step)
        _ -> Left ("Ambiguous center step at " ++ show address)

