{-# LANGUAGE OverloadedStrings #-}
module Workbench.Runtime (runRequest) where

import Data.Aeson
import qualified Data.ByteString.Lazy as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Workbench.Compile (compileOntology, compileSelector)

data Request = Compile String String | Query String String String

instance FromJSON Request where
  parseJSON = withObject "workbench request" $ \fields -> do
    operation <- fields .: "operation"
    case (operation :: String) of
      "compile" -> Compile <$> fields .: "root" <*> fields .: "source"
      "query" -> Query <$> fields .: "root" <*> fields .: "source" <*> fields .: "query"
      _ -> fail "Unknown workbench operation"

-- Only the transport changes between native and browser builds. Both call the
-- same parser, compiler and interpreter functions and preserve exact JSON text.
runRequest :: String -> String
runRequest source = T.unpack . T.decodeUtf8 . B.toStrict . encode $ case request of
  Left message -> object ["ok" .= False, "error" .= message]
  Right value -> object ["ok" .= True, "value" .= value]
  where
    request = eitherDecode (B.fromStrict (T.encodeUtf8 (T.pack source))) >>= execute
    execute (Compile root ontology) = compileOntology root ontology
    execute (Query root ontology query) = compileSelector root ontology query
