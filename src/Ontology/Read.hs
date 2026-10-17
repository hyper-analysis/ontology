module Ontology.Read
  ( Scalar(..), Instance(..), Read(..), readAt
  , validateRead, instantiateView, bindArguments
  ) where

import Prelude hiding (Read)
import Control.Monad (unless)
import qualified Data.Map.Strict as M
import Data.Time (UTCTime)
import Ontology.Center.Graph
import Ontology.Projection
import Ontology.Views
import qualified Ontology.Relational as R
import qualified Ontology.Syntax as O

data Scalar
  = StringValue String
  | NumberValue Rational
  | BooleanValue Bool
  | TimestampValue UTCTime
  deriving (Eq, Show)

data Instance = Instance
  { instancePopulation :: O.Name
  , instanceArguments :: [(O.Name, Scalar)]
  } deriving (Eq, Show)

data Read = Read
  { readInstance :: Instance
  , readFocus :: R.Path
  , readProjection :: Projection
  } deriving (Eq, Show)

readAt :: Instance -> R.Path -> Projection -> Read
readAt = Read

-- This is validation/ordering, not query compilation. A prepared query can be
-- compiled once and invoked many times. Named arguments are order-independent.
bindArguments :: [Parameter] -> [(String, Scalar)] -> Either String [Scalar]
bindArguments parameters supplied = do
  let values = M.fromList supplied
      expected = M.fromList [(parameterName p, ()) | p <- parameters]
  unless (M.size values == length supplied) (Left "Duplicate invocation argument")
  unless (M.keysSet values == M.keysSet expected)
    (Left ("Invocation arguments must be exactly " ++ show (M.keys expected)))
  mapM (one values) parameters
  where
    one values p = case M.lookup (parameterName p) values of
      Just value | compatible (parameterAtom p) value -> Right value
      _ -> Left ("Invalid value for semantic parameter " ++ parameterName p)

instantiateView :: PreparedView -> [Scalar] -> Either String Read
instantiateView view values = do
  unless (length values == length (preparedParameters view))
    (Left "View invocation has the wrong number of parameters")
  let arguments = zip (map parameterName (preparedParameters view)) values
  _ <- bindArguments (preparedParameters view) arguments
  pure (Read (Instance (preparedPopulation view) arguments)
    (addressPath (preparedCenter view)) (preparedProjection view))

validateRead :: World -> Read -> Either String ()
validateRead graph request = do
  let inst = readInstance request
      address = within (population (instancePopulation inst)) (readFocus request)
      p = readProjection request
  s <- siteAt graph address
  unless (projectedAddress p == address && projectedKey p == siteKey s
          && projectedGuards p == siteGuards s && projectedKind p == siteKind s)
    (Left "Projection center metadata does not match the bound occurrence")
  signature <- keyParameters
    (fmap (map keyPart . siteKey) . siteAt graph . population) (siteKey s)
  _ <- bindArguments signature (instanceArguments inst)
  pure ()

compatible :: R.Atom -> Scalar -> Bool
compatible (R.ScalarAtom O.TString) (StringValue _) = True
compatible (R.ScalarAtom O.TNumber) (NumberValue _) = True
compatible (R.ScalarAtom O.TBoolean) (BooleanValue _) = True
compatible (R.ScalarAtom O.TTimestamp) (TimestampValue _) = True
compatible (R.LiteralAtom literal) value = literalMatches literal value
compatible (R.EnumAtom literals) value = any (`literalMatches` value) literals
compatible _ _ = False

literalMatches :: O.Literal -> Scalar -> Bool
literalMatches (O.TextLiteral x) (StringValue y) = x == y
literalMatches (O.NumberLiteral x) (NumberValue y) = toRational x == y
literalMatches (O.BooleanLiteral x) (BooleanValue y) = x == y
literalMatches _ _ = False

