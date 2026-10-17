module Ontology.Center
  ( Address(..)
  , Cardinality(..)
  , OwnerKind(..)
  , Owner(..)
  , Center(..)
  , population
  , within
  , center
  , addresses
  ) where

import Data.List (nub, sortOn)
import qualified Data.Map.Strict as M
import Ontology.Syntax (Name)
import qualified Ontology.Relational as R

-- A center is an address in the relational meaning, not an SQL table.
-- Paths are concatenations of dependent paths from a population root.
data Address = Address
  { addressPopulation :: Name
  , addressPath :: R.Path
  } deriving (Eq, Ord, Show)

data Cardinality
  = One
  | Many
  deriving (Eq, Ord, Show)

data OwnerKind
  = Containing R.Boundary
  | Referencing
  deriving (Eq, Show)

data Owner = Owner
  { ownerAddress :: Address
  , ownerRelation :: R.Path
  , ownerCardinality :: Cardinality
  , ownerKind :: OwnerKind
  , ownerPresence :: [R.Presence]
  } deriving (Eq, Show)

data Center = Center
  { centerAddress :: Address
  , centerIdentity :: Name
  , centerRow :: R.Row
  , centerOwners :: [Owner]
  } deriving (Eq, Show)

data Located = Located
  { locatedAddress :: Address
  , locatedIdentity :: Name
  , locatedParent :: Maybe (Address, R.Dependent)
  , locatedAddedKey :: [R.KeyColumn]
  , locatedRow :: R.Row
  } deriving (Eq, Show)

population :: Name -> Address
population name =
  Address name []

within :: Address -> R.Path -> Address
within address path =
  address { addressPath = addressPath address ++ path }

center :: R.Relational -> Address -> Either String Center
center meaning target = do
  located <- locate meaning target
  let structural =
        case locatedParent located of
          Nothing ->
            []

          Just (parentAddress, dependent) ->
            [ Owner
                { ownerAddress = parentAddress
                , ownerRelation = R.dependentPath dependent
                , ownerCardinality = One
                , ownerKind = Containing (R.boundary dependent)
                , ownerPresence = R.dependentPresence dependent
                }
            ]

      incoming =
        concatMap
          (referenceOwners (locatedIdentity located))
          (allLocated meaning)

      owners =
        sortOn ownerSortKey (nub (structural ++ incoming))

  pure
    Center
      { centerAddress = target
      , centerIdentity = locatedIdentity located
      , centerRow = locatedRow located
      , centerOwners = owners
      }

addresses :: R.Relational -> [Address]
addresses =
  map locatedAddress . allLocated

locate :: R.Relational -> Address -> Either String Located
locate meaning target =
  case filter ((== target) . locatedAddress) (allLocated meaning) of
    [one] ->
      Right one

    [] ->
      Left ("unknown relational center " ++ show target)

    _ ->
      Left ("ambiguous relational center " ++ show target)

allLocated :: R.Relational -> [Located]
allLocated meaning =
  concat
    [ descend
        name
        (Address name [])
        Nothing
        []
        (R.populationValue population')
    | (name, population') <- M.toAscList (R.populations meaning)
    ]

descend
  :: Name
  -> Address
  -> Maybe (Address, R.Dependent)
  -> [R.KeyColumn]
  -> R.Row
  -> [Located]
descend identity address parent localKey row =
  current : concatMap child (R.dependents row)
  where
    current =
      Located
        { locatedAddress = address
        , locatedIdentity = identity
        , locatedParent = parent
        , locatedAddedKey = localKey
        , locatedRow = row
        }

    child dependent =
      let childAddress =
            within address (R.dependentPath dependent)

          childKey =
            R.addedKey dependent

      in
        descend
          identity
          childAddress
          (Just (address, dependent))
          childKey
          (R.contents dependent)

referenceOwners :: Name -> Located -> [Owner]
referenceOwners target located =
  columnOwners ++ keyOwners
  where
    row =
      locatedRow located

    columnOwners =
      [ Owner
          { ownerAddress = locatedAddress located
          , ownerRelation = R.columnPath column'
          , ownerCardinality =
              if uniqueAt (R.columnPath column') (R.rules row)
                then One
                else Many
          , ownerKind = Referencing
          , ownerPresence = R.columnPresence column'
          }
      | column' <- R.columns row
      , R.ReferenceAtom referenceTarget <- [R.columnAtom column']
      , referenceTarget == target
      ]

    keyOwners =
      [ Owner
          { ownerAddress = locatedAddress located
          , ownerRelation = R.keyPath key
          , ownerCardinality = Many
          , ownerKind = Referencing
          , ownerPresence = []
          }
      | key <- locatedAddedKey located
      , R.ReferenceAtom referenceTarget <- [R.keyAtom key]
      , referenceTarget == target
      ]

uniqueAt :: R.Path -> [R.Rule] -> Bool
uniqueAt path =
  any matches
  where
    matches rule =
      case rule of
        R.UniqueValue uniquePath ->
          uniquePath == path

ownerSortKey :: Owner -> (Name, R.Path, R.Path, Cardinality)
ownerSortKey owner =
  ( addressPopulation (ownerAddress owner)
  , addressPath (ownerAddress owner)
  , ownerRelation owner
  , ownerCardinality owner
  )

