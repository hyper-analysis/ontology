{-# LANGUAGE OverloadedStrings #-}
module Application.Input (InputPage(..), parseApplication, preparePages) where

import Control.Monad (unless)
import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Application.Compiler (PageSpec(..))
import Ontology.Center.Graph (World, Primitive(..))
import qualified Ontology.Projection as P
import qualified Ontology.Views as W

data InputPage = InputPage String String W.ViewSource deriving (Eq, Show)
newtype Document = Document [InputPage]

onlyKeys :: [K.Key] -> Object -> Parser ()
onlyKeys allowed record = unless (all (`elem` allowed) (KM.keys record))
  (fail "Unknown property in application manifest")

instance FromJSON Document where
  parseJSON = withObject "application" $ \o -> do
    onlyKeys ["pages"] o
    Document <$> o .: "pages"

instance FromJSON InputPage where
  parseJSON = withObject "page" $ \o -> do
    onlyKeys ["name","title","population","center","depth","references","direction","repeat","fields"] o
    name <- o .: "name"
    title <- o .: "title"
    population <- o .: "population"
    center <- o .:? "center" .!= [] >>= mapM parseStep
    depth <- o .:? "depth" .!= 3
    unless (depth >= 0) (fail "View depth must be nonnegative")
    refs <- o .:? "references" .!= ("keys" :: String)
    referencePolicy <- case refs of
      "keys" -> pure P.ReferenceLinks
      "follow" -> pure P.FollowReferences
      _ -> fail "references must be keys or follow"
    direction <- o .:? "direction" .!= ("out" :: String)
    directionPolicy <- case direction of
      "out" -> pure P.OutgoingOnly
      "in" -> pure P.IncomingOnly
      "both" -> pure P.Both
      _ -> fail "direction must be out, in, or both"
    repeated <- o .:? "repeat" .!= False
    fields <- o .:? "fields"
    let selection = maybe P.AllEdges (P.OnlyEdges . map (P.Through . Field)) fields
        config = P.Projector depth directionPolicy referencePolicy
          (if repeated then P.AllowRepeats else P.StopAtRepeatedAddress) selection
    pure (InputPage name title (W.ViewSource name population center config))
    where
      parseStep :: Value -> Parser W.CenterStep
      parseStep (String "items") = pure W.CenterElements
      parseStep (String "entries") = pure W.CenterEntries
      parseStep (String "tag") = pure W.CenterTag
      parseStep (String name) = pure (W.CenterField (T.unpack name))
      parseStep value = withObject "center step" (\o -> case KM.toList o of
        [("field",v)] -> W.CenterField <$> parseJSON v
        [("argument",v)] -> W.CenterArgument <$> parseJSON v
        [("case",v)] -> do
          n <- parseJSON v
          unless (n >= 0) (fail "Alternative index must be nonnegative")
          pure (W.CenterBranch n)
        _ -> fail "A center step must contain exactly field, argument, or case") value

parseApplication :: String -> Either String [InputPage]
parseApplication input = do
  Document pages <- eitherDecode (B.fromStrict (T.encodeUtf8 (T.pack input)))
  pure pages

preparePages :: World -> [InputPage] -> Either String [PageSpec]
preparePages graph = mapM one
  where one (InputPage name title source) = PageSpec name title <$> W.prepareView graph source

