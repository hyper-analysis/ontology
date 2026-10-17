module Ontology.Labels.Parser
  ( Catalog(..), Declaration(..), Item(..), Step(..), parseLabels, parseLabelsFile
  ) where

import Control.Monad (void, when)
import Data.Char (isAlphaNum, ord, chr, digitToInt)
import qualified Data.List.NonEmpty as NE
import Data.Void (Void)
import Text.Megaparsec hiding (choice)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L
import Ontology.Labels.Types
import qualified Ontology.Syntax as O

data Catalog = Catalog String [Declaration] deriving (Eq, Show)
data Declaration
  = Labels Location String [Item]
  | System Location [(Location, String, String)]
  deriving (Eq, Show)
data Item
  = Caption Location (Maybe Form) String
  | Inverse Location [Item]
  | Choice Location O.Literal String
  | Nested Location Step [Item]
  deriving (Eq, Show)
data Step
  = FieldStep String
  | ItemsStep
  | EntriesStep
  | ArgumentStep String
  | TagStep String
  | BranchStep String
  deriving (Eq, Show)

type Parser = Parsec Void String

spaceConsumer :: Parser ()
spaceConsumer = L.space space1 (L.skipLineComment "//") (L.skipBlockComment "/*" "*/")

symbol :: String -> Parser String
symbol = L.symbol spaceConsumer

keyword :: String -> Parser ()
keyword s = L.lexeme spaceConsumer . try $ string s *> notFollowedBy (satisfy (\c -> isAlphaNum c || c == '_'))

-- JSON string escaping; exportTemplate and machine-generated catalogs use the
-- same grammar. Unicode surrogate pairs decode to one scalar, never two chars.
quoted :: Parser String
quoted = L.lexeme spaceConsumer (char '"' *> many character <* char '"')
  where
    character = satisfy (\c -> ord c >= 32 && c /= '"' && c /= '\\' && not (surrogate (ord c)))
      <|> (char '\\' *> escaped)
    escaped = '"' <$ char '"' <|> '\\' <$ char '\\' <|> '/' <$ char '/'
      <|> '\b' <$ char 'b' <|> '\f' <$ char 'f' <|> '\n' <$ char 'n'
      <|> '\r' <$ char 'r' <|> '\t' <$ char 't' <|> (char 'u' *> unicode)
    hex = foldl (\n c -> 16 * n + digitToInt c) 0 <$> count 4 hexDigitChar
    unicode = do
      n <- hex
      if n >= 0xD800 && n <= 0xDBFF then do
        void (string "\\u")
        low <- hex
        when (low < 0xDC00 || low > 0xDFFF) (fail "Expected a Unicode low surrogate")
        pure (chr (0x10000 + (n - 0xD800) * 1024 + low - 0xDC00))
      else if surrogate n then fail "Unpaired Unicode surrogate" else pure (chr n)
    surrogate n = n >= 0xD800 && n <= 0xDFFF

identifier :: Parser String
identifier = quoted <|> L.lexeme spaceConsumer ((:) <$> (letterChar <|> char '_') <*> many (alphaNumChar <|> char '_'))

location :: Parser Location
location = do
  p <- getSourcePos
  pure (Location (sourceName p) (unPos (sourceLine p)) (unPos (sourceColumn p)))

formP :: Parser Form
formP = Singular <$ keyword "singular" <|> Plural <$ keyword "plural"

assignment :: Parser String
assignment = symbol "=" *> quoted <* symbol ";"

literalP :: Parser O.Literal
literalP = O.TextLiteral <$> quoted
  <|> O.BooleanLiteral True <$ keyword "true"
  <|> O.BooleanLiteral False <$ keyword "false"
  <|> O.NumberLiteral <$> L.lexeme spaceConsumer (L.signed spaceConsumer L.scientific)

-- Recover at the next statement boundary. Registered errors remain fatal;
-- partial catalogs are never compiled. Strings and balanced nested groups do
-- not expose their internal semicolons as recovery points.
recoverStatement :: Bool -> ParseError String Void -> Parser [a]
recoverStatement inner err = do
  registerParseError err
  let group = char '{' *> many (void (try quoted) <|> void (try group) <|> void (satisfy (/= '}'))) <* char '}'
      piece = void (try quoted) <|> void (try group) <|> void (satisfy (\c -> c /= ';' && c /= '}'))
  void (many piece)
  void (optional (char ';'))
  when (not inner) (void (optional (char '}')))
  spaceConsumer
  pure []

block :: Parser [Item]
block = symbol "{" *> (concat <$> many one) <* symbol "}"
  where
    one = notFollowedBy (char '}') *> notFollowedBy eof
      *> withRecovery (recoverStatement True) ((:[]) <$> item)

item :: Parser Item
item = do
  at <- location
  common at <|> caption at <|> inverseBlock at <|> try (choice at) <|> nested at
  where
    common at = Caption at Nothing <$> assignment
    caption at = Caption at . Just <$> formP <*> assignment
    inverseBlock at = keyword "inverse" *> (Inverse at <$> block)
    choice at = keyword "case" *> (Choice at <$> literalP <*> assignment)
    nested at = do
      step <- FieldStep <$> (keyword "field" *> identifier)
        <|> ItemsStep <$ keyword "items"
        <|> EntriesStep <$ keyword "entries"
        <|> ArgumentStep <$> (keyword "argument" *> identifier)
        <|> TagStep <$> (keyword "tag" *> identifier)
        <|> BranchStep <$> (keyword "case" *> identifier)
        <|> FieldStep <$> identifier
      Nested at step <$> block

catalogP :: Parser Catalog
catalogP = do
  spaceConsumer
  keyword "language"
  language <- identifier
  void (symbol ";")
  declarations <- concat <$> many (notFollowedBy eof *> withRecovery (recoverStatement False) declaration)
  eof
  pure (Catalog language declarations)
  where
    declaration = do
      at <- location
      (:[]) <$> (Labels at <$> (keyword "labels" *> identifier) <*> block
        <|> System at <$> (keyword "system" *> systemP))
    systemP = symbol "{" *> (concat <$> many systemEntry) <* symbol "}"
    systemEntry = notFollowedBy (char '}') *> notFollowedBy eof
      *> withRecovery (recoverStatement True) (do
        at <- location
        key <- identifier
        value <- assignment
        pure [(at,key,value)])

parseLabels :: FilePath -> String -> Either [Diagnostic] Catalog
parseLabels file input = case parse catalogP file input of
  Right catalog -> Right catalog
  Left bundle -> Left (map (diagnostic bundle) (NE.toList (bundleErrors bundle)))
  where
    diagnostic bundle err =
      let (_, state) = reachOffset (errorOffset err) (bundlePosState bundle)
          p = pstateSourcePos state
      in Diagnostic Error "syntax" "label file" (parseErrorTextPretty err)
        (Just (Location (sourceName p) (unPos (sourceLine p)) (unPos (sourceColumn p))))

parseLabelsFile :: FilePath -> IO (Either [Diagnostic] Catalog)
parseLabelsFile file = parseLabels file <$> readFile file

