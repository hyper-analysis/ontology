module OSQL.Parser
  ( ParseError, parseProgram, parseProgramFile, parseExpression
  , renderParseError
  ) where

import Control.Applicative (many, some)
import Control.Monad (void, when)
import Data.Char (chr, digitToInt, generalCategory, isLetter, ord, GeneralCategory(DecimalNumber))
import Data.List.NonEmpty (NonEmpty(..))
import Data.Void (Void)
import OSQL.Syntax
import Text.Megaparsec hiding (ParseError, SourcePos, parse, some, many)
import Text.Megaparsec.Char (char, string)
import qualified Text.Megaparsec as M
import qualified Text.Megaparsec.Char.Lexer as L

type Parser = Parsec Void String
type ParseError = ParseErrorBundle String Void

parseProgram :: FilePath -> String -> Either ParseError Program
parseProgram = runParser (spaceConsumer *> programP <* eof)

parseProgramFile :: FilePath -> IO (Either ParseError Program)
parseProgramFile file = parseProgram file <$> readFile file

parseExpression :: FilePath -> String -> Either ParseError Expr
parseExpression = runParser (spaceConsumer *> expressionP <* eof)

renderParseError :: ParseError -> String
renderParseError = errorBundlePretty

spaceConsumer :: Parser ()
spaceConsumer = L.space (void (some (oneOf " \t\r\n")))
  (L.skipLineComment "//") empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme spaceConsumer

symbol :: String -> Parser ()
symbol = void . L.symbol spaceConsumer

identifierStart :: Char -> Bool
identifierStart c = isLetter c || c == '_'

identifierRest :: Char -> Bool
identifierRest c = identifierStart c || generalCategory c == DecimalNumber

rawWord :: Parser String
rawWord = (:) <$> satisfy identifierStart <*> many (satisfy identifierRest)

reserved :: [String]
reserved =
  [ "select", "from", "as", "let", "where", "root", "true", "false"
  , "null", "match", "not", "and", "or", "implies", "in", "exists"
  , "exist", "every", "count", "entries", "only", "first", "at", "timestamp", "_"
  ]

identifier :: Parser Name
identifier = lexeme . try $ do
  name <- rawWord
  when (name `elem` reserved) (fail ("reserved name " ++ show name))
  pure name

labelP :: Parser Name
labelP = lexeme rawWord

rawKeyword :: String -> Parser ()
rawKeyword word = void . try $ string word <* notFollowedBy (satisfy identifierRest)

keyword :: String -> Parser ()
keyword = lexeme . rawKeyword

positionP :: Parser Position
positionP = do
  offset <- getOffset
  pos <- getSourcePos
  pure (Position offset (unPos (M.sourceLine pos)) (unPos (M.sourceColumn pos)))

located :: Parser a -> Parser (Located a)
located parser = do
  file <- M.sourceName <$> getSourcePos
  start <- positionP
  value <- parser
  end <- positionP
  pure (Located (SourceSpan file start end) value)

cover :: Located a -> Located b -> SourceSpan
cover left right = SourceSpan
  (spanFile (sourceSpan left)) (spanStart (sourceSpan left)) (spanEnd (sourceSpan right))

nonemptySeparated :: Parser a -> Parser () -> Parser (NonEmpty a)
nonemptySeparated item separator = (:|) <$> item <*> many (separator *> item)

parenthesized :: Parser a -> Parser a
parenthesized = between (symbol "(") (symbol ")")

programP :: Parser Program
programP = Program <$> many definitionP <*> (expressionP <* optional (symbol ";"))

definitionP :: Parser Binding
definitionP = located $ do
  keyword "let"
  name <- identifier
  symbol "="
  result <- expressionP
  symbol ";"
  pure (Binding name result)

expressionP :: Parser Expr
expressionP = located (Select <$> queryP) <|> valueP

queryP :: Parser Query
queryP = do
  selection <- lexeme $ do
    rawKeyword "select"
    option AllResults (SingleResult <$ char '!')
  projection <- projectionP
  keyword "from"
  sources <- nonemptySeparated sourceP (symbol ",")
  steps <- many stepP
  pure (Query selection projection sources steps)

projectionP :: Parser Projection
projectionP = do
  value <- valueP
  name <- optional (keyword "as" *> labelP)
  case name of
    Nothing -> pure (Single value)
    Just outputName -> NamedProjection . ((outputName, value) :|) <$> many (symbol "," *> namedProjectionP)

namedProjectionP :: Parser (Name, Expr)
namedProjectionP = do
  value <- valueP
  keyword "as"
  name <- labelP
  pure (name, value)

sourceP :: Parser Source
sourceP = located (Source <$> valueP <* keyword "as" <*> identifier)

stepP :: Parser Step
stepP = located $
      Let <$> located (Binding <$ keyword "let" <*> identifier <* symbol "=" <*> valueP)
  <|> Where <$ keyword "where" <*> valueP

valueP :: Parser Expr
valueP = implicationP

implicationP :: Parser Expr
implicationP = do
  left <- disjunctionP
  right <- optional (keyword "implies" *> implicationP)
  pure (maybe left (binary Implies left) right)

disjunctionP :: Parser Expr
disjunctionP = leftAssociative conjunctionP (Or <$ keyword "or")

conjunctionP :: Parser Expr
conjunctionP = leftAssociative negationP (And <$ keyword "and")

leftAssociative :: Parser Expr -> Parser BinaryOp -> Parser Expr
leftAssociative operand operator = do
  first <- operand
  rest <- many ((,) <$> operator <*> operand)
  pure (foldl (\left (op, right) -> binary op left right) first rest)

binary :: BinaryOp -> Expr -> Expr -> Expr
binary operator left right = Located (cover left right) (Binary operator left right)

negationP :: Parser Expr
negationP = located (Not <$ keyword "not" <*> negationP) <|> comparisonP

comparisonP :: Parser Expr
comparisonP = do
  left <- postfixP
  right <- optional ((,) <$> comparisonOperatorP <*> postfixP)
  pure (maybe left (\(op, value) -> binary op left value) right)

comparisonOperatorP :: Parser BinaryOp
comparisonOperatorP = choice
  [ LessEqual <$ symbol "<=", GreaterEqual <$ symbol ">="
  , Equal <$ symbol "=", Less <$ symbol "<", Greater <$ symbol ">"
  , Member <$ keyword "in"
  ]

postfixP :: Parser Expr
postfixP = located (Group <$> parenthesized expressionP)
  <|> located (PostfixExpr <$> primaryP <*> many suffixP)

suffixP :: Parser Postfix
suffixP = located $
      OptionalField <$ symbol "?." <*> labelP
  <|> Field <$ symbol "." <*> labelP
  <|> Apply <$> parenthesized argumentsP

argumentsP :: Parser Arguments
argumentsP = do
  named <- optional (try (lookAhead (labelP <* symbol ":")))
  case named of
    Nothing -> Positional <$> valueP
    Just _ -> Named <$> nonemptySeparated namedArgumentP (symbol ",")

namedArgumentP :: Parser (Name, Expr)
namedArgumentP = (,) <$> labelP <* symbol ":" <*> valueP

primaryP :: Parser Primary
primaryP = located $ choice
  [ Root <$ keyword "root"
  , Literal (BooleanLiteral True) <$ keyword "true"
  , Literal (BooleanLiteral False) <$ keyword "false"
  , Literal NullLiteral <$ keyword "null"
  , Literal . TextLiteral <$> stringLiteralP
  , Literal . NumberLiteral <$> numberLiteralP
  , Literal . TimestampLiteral <$ keyword "timestamp" <*> parenthesized stringLiteralP
  , Record <$> between (symbol "{") (symbol "}") (namedArgumentP `sepBy` symbol ",")
  , matchP
  , existenceP
  , Quantified Every <$ keyword "every" <*> identifier <* keyword "in" <*> valueP
      <*> between (symbol "{") (symbol "}") valueP
  , builtinP
  , atP
  , Variable <$> identifier
  ]

atP :: Parser PrimaryNode
atP = do
  keyword "at"
  symbol "("
  collection <- valueP
  symbol ","
  index <- valueP
  symbol ")"
  pure (At collection index)

matchP :: Parser PrimaryNode
matchP = Match <$ keyword "match" <*> valueP
  <*> between (symbol "{") (symbol "}") matchArmsP

matchArmsP :: Parser MatchArms
matchArmsP = DefaultOnly <$> fallbackP
  <|> NamedArms <$> ((:|) <$> caseArmP <*> many caseArmP) <*> optional fallbackP

caseArmP :: Parser CaseArm
caseArmP = located $ do
  notFollowedBy (rawKeyword "_")
  name <- labelP
  binder <- identifier
  symbol "=>"
  result <- expressionP
  symbol ";"
  pure (CaseArm name binder result)

fallbackP :: Parser Expr
fallbackP = keyword "_" *> symbol "=>" *> expressionP <* symbol ";"

existenceP :: Parser PrimaryNode
existenceP = do
  existence <- lexeme $
        UniqueResult <$ (rawKeyword "exist" *> char '!')
    <|> (rawKeyword "exists" *> option NonEmptyResult (UniqueResult <$ char '!'))
  case existence of
    UniqueResult -> Exists UniqueResult <$> parenthesized expressionP
    NonEmptyResult -> Exists NonEmptyResult <$> parenthesized expressionP
      <|> Quantified Some <$> identifier <* keyword "in" <*> valueP
          <*> between (symbol "{") (symbol "}") valueP

builtinP :: Parser PrimaryNode
builtinP = Builtin <$> choice
  [Count <$ keyword "count", Entries <$ keyword "entries", Only <$ keyword "only", First <$ keyword "first"]
  <*> parenthesized valueP

stringLiteralP :: Parser String
stringLiteralP = lexeme (char '"' *> many jsonCharacterP <* char '"')

jsonCharacterP :: Parser Char
jsonCharacterP =
      satisfy (\c -> ord c >= 32 && c /= '"' && c /= '\\' && not (surrogate (ord c)))
  <|> char '\\' *> escapedCharacterP

escapedCharacterP :: Parser Char
escapedCharacterP = choice
  [ '"' <$ char '"', '\\' <$ char '\\', '/' <$ char '/'
  , '\b' <$ char 'b', '\f' <$ char 'f', '\n' <$ char 'n'
  , '\r' <$ char 'r', '\t' <$ char 't'
  , char 'u' *> unicodeEscapeP
  ]

surrogate :: Int -> Bool
surrogate code = code >= 0xd800 && code <= 0xdfff

hexCodeP :: Parser Int
hexCodeP = foldl (\value digit -> value * 16 + digitToInt digit) 0
  <$> count 4 (oneOf "0123456789abcdefABCDEF")

unicodeEscapeP :: Parser Char
unicodeEscapeP = do
  code <- hexCodeP
  if code >= 0xd800 && code <= 0xdbff
    then do
      void (string "\\u")
      low <- hexCodeP
      when (low < 0xdc00 || low > 0xdfff) (fail "expected a low surrogate escape")
      pure (chr (0x10000 + (code - 0xd800) * 1024 + low - 0xdc00))
    else do
      when (code == 0 || surrogate code) (fail "NUL and unpaired surrogates are not text values")
      pure (chr code)

numberLiteralP :: Parser Decimal
numberLiteralP = lexeme $ do
  sign <- option 1 (-1 <$ char '-')
  whole <- ((:[]) <$> char '0') <|> ((:) <$> oneOf "123456789" <*> many asciiDigitP)
  fraction <- option [] (try (char '.' *> some asciiDigitP))
  decimalExponent <- option 0 $ do
    void (oneOf "eE")
    exponentSign <- option 1 ((-1 <$ char '-') <|> (1 <$ char '+'))
    digits <- some asciiDigitP
    pure (exponentSign * read digits)
  pure (Decimal (sign * read (whole ++ fraction)) (decimalExponent - toInteger (length fraction)))

asciiDigitP :: Parser Char
asciiDigitP = oneOf "0123456789"

