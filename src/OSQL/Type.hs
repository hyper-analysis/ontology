-- Query types are semantic values, separate from storage and source syntax.
module OSQL.Type
  ( Type(..), AtomicLiteral(..), union, optional, nonNull, nullable
  , assignable, equalityCompatible, primitiveOf, prettyType, decimal
  ) where

import Data.List (nub, sortOn, intercalate)
import qualified Ontology.Syntax as O
import qualified OSQL.Syntax as S

data AtomicLiteral = Text String | Number S.Decimal | Boolean Bool
  deriving (Eq, Show)

data Type
  = Primitive O.Primitive
  | Literal AtomicLiteral
  | Enum [AtomicLiteral]
  | Entity String
  | Record [(String, Type)]
  | Variant String [(String, Type)]
  | Null
  | Union [Type]
  | Set Type
  | Sequence Type
  | Map [(String, Type)] Type
  deriving (Eq, Show)

-- Canonicalize finite decimals without allocating 10^exponent.
decimal :: Integer -> Integer -> S.Decimal
decimal 0 _ = S.Decimal 0 0
decimal coefficient exponentValue
  | coefficient `mod` 10 == 0 = decimal (coefficient `div` 10) (exponentValue + 1)
  | otherwise = S.Decimal coefficient exponentValue

primitiveOf :: AtomicLiteral -> O.Primitive
primitiveOf (Text _) = O.TString
primitiveOf (Number _) = O.TNumber
primitiveOf (Boolean _) = O.TBoolean

alternatives :: Type -> [Type]
alternatives (Union xs) = concatMap alternatives xs
alternatives t = [t]

union :: [Type] -> Type
union ts = case foldl include [] (concatMap alternatives ts) of
  [x] -> x
  xs -> Union xs
  where
    include previous incoming
      | any (assignable incoming) previous = previous
      | otherwise = filter (not . (`assignable` incoming)) previous ++ [incoming]

optional :: Type -> Type
optional t = union [t, Null]

nonNull :: Type -> Maybe Type
nonNull t = case filter (/= Null) (alternatives t) of
  [] -> Nothing
  xs -> Just (union xs)

nullable :: Type -> Bool
nullable = elem Null . alternatives

assignable :: Type -> Type -> Bool
assignable (Union xs) target = all (`assignable` target) xs
assignable source (Union ys) = any (assignable source) ys
assignable source target | source == target = True
assignable (Literal x) (Primitive p) = primitiveOf x == p
assignable (Literal x) (Enum ys) = x `elem` ys
assignable (Enum xs) (Primitive p) = all ((== p) . primitiveOf) xs
assignable (Enum xs) (Enum ys) = all (`elem` ys) xs
assignable (Record xs) (Record ys) = sameFields assignable xs ys
assignable (Set x) (Set y) = assignable x y
assignable (Sequence x) (Sequence y) = assignable x y
assignable _ _ = False

sameFields :: (Type -> Type -> Bool) -> [(String,Type)] -> [(String,Type)] -> Bool
sameFields test xs ys = map fst a == map fst b && and (zipWith (\(_,x) (_,y) -> test x y) a b)
  where a = sortOn fst xs; b = sortOn fst ys

families :: Type -> [O.Primitive]
families (Primitive p) = [p]
families (Literal x) = [primitiveOf x]
families (Enum xs) = nub (map primitiveOf xs)
families _ = []

equalityCompatible :: Type -> Type -> Bool
equalityCompatible (Union xs) y = any (`equalityCompatible` y) xs
equalityCompatible x (Union ys) = any (equalityCompatible x) ys
equalityCompatible Null _ = True
equalityCompatible _ Null = True
equalityCompatible (Entity a) (Entity b) = a == b
equalityCompatible (Record xs) (Record ys) = sameFields equalityCompatible xs ys
equalityCompatible (Set x) (Set y) = equalityCompatible x y
equalityCompatible (Sequence x) (Sequence y) = equalityCompatible x y
equalityCompatible (Variant t xs) (Variant u ys) = t == u && xs == ys
equalityCompatible (Map xs x) (Map ys y) = sameFields equalityCompatible xs ys && equalityCompatible x y
equalityCompatible x y = any (`elem` families y) (families x)

prettyType :: Type -> String
prettyType (Primitive O.TString) = "Text"
prettyType (Primitive O.TNumber) = "Number"
prettyType (Primitive O.TBoolean) = "Boolean"
prettyType (Primitive O.TTimestamp) = "Timestamp"
prettyType (Literal x) = show x
prettyType (Enum xs) = "Enum" ++ show xs
prettyType (Entity name) = "Entity(" ++ name ++ ")"
prettyType (Record fs) = "Record{" ++ intercalate ", " [n ++ ":" ++ prettyType t | (n,t) <- fs] ++ "}"
prettyType (Variant tag _) = "Variant(" ++ tag ++ ")"
prettyType Null = "Null"
prettyType (Union xs) = intercalate " | " (map prettyType xs)
prettyType (Set t) = "Set(" ++ prettyType t ++ ")"
prettyType (Sequence t) = "Sequence(" ++ prettyType t ++ ")"
prettyType (Map ps t) = "Map(" ++ intercalate ", " [n ++ ":" ++ prettyType p | (n,p) <- ps] ++ "; " ++ prettyType t ++ ")"

