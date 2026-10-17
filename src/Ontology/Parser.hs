{-# LANGUAGE OverloadedStrings #-}
module Ontology.Parser
  ( parseModule, parseModuleFile, parseModuleLocated, SourceSpan(..), SourceLocation(..) ) where

import Control.Monad (void)
import Data.Char (isAlphaNum)
import qualified Data.Map.Strict as M
import Data.Scientific (Scientific)
import Data.Void (Void)
import Ontology.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

type Parser = Parsec Void String

-- Offsets are Unicode code points, as used by Megaparsec's String stream.
data SourceSpan = SourceSpan { spanStart :: Int, spanEnd :: Int } deriving (Eq, Show)
data SourceLocation = SourceLocation
  { locationDeclaration :: Name, locationPath :: [Name], locationSpan :: SourceSpan }
  deriving (Eq, Show)
data Located = Located TypeExpr [([Name], SourceSpan)]

plain :: TypeExpr -> Located
plain t = Located t []

wrapped :: (TypeExpr -> TypeExpr) -> Located -> Located
wrapped f (Located t ls) = Located (f t) ls

combined :: ([TypeExpr] -> TypeExpr) -> [Located] -> Located
combined _ [x] = x
combined f xs = Located (f [t | Located t _ <- xs]) (concat [ls | Located _ ls <- xs])

spaceConsumer :: Parser ()
spaceConsumer = L.space space1 (L.skipLineComment "//") (L.skipBlockComment "/*" "*/")

lexeme :: Parser a -> Parser a
lexeme = L.lexeme spaceConsumer

symbol :: String -> Parser String
symbol = L.symbol spaceConsumer

reserved :: [String]
reserved = ["type","string","number","boolean","timestamp","Ref","unique","key","alternative","true","false"]

identifierToken :: Parser String
identifierToken = try $ do
  first <- letterChar <|> char '_'
  rest <- many (satisfy (\c -> isAlphaNum c || c == '_'))
  let name = first : rest
  if name `elem` reserved then fail ("reserved word " ++ show name) else pure name

identifier :: Parser String
identifier = lexeme identifierToken

locatedIdentifier :: Parser (Name, SourceSpan)
locatedIdentifier = lexeme $ do
  start <- getOffset
  name <- identifierToken
  end <- getOffset
  pure (name, SourceSpan start end)

keyword :: String -> Parser ()
keyword k = lexeme . try $ string k *> notFollowedBy (satisfy (\c -> isAlphaNum c || c == '_'))

stringLiteral :: Parser String
stringLiteral = lexeme (char '"' *> manyTill L.charLiteral (char '"'))

numberLiteral :: Parser Scientific
numberLiteral = lexeme (L.signed spaceConsumer L.scientific)

literalP :: Parser Literal
literalP = TextLiteral <$> stringLiteral
  <|> NumberLiteral <$> try numberLiteral
  <|> BooleanLiteral True <$ keyword "true"
  <|> BooleanLiteral False <$ keyword "false"

primitiveP :: Parser Located
primitiveP = plain (Primitive TString) <$ keyword "string"
  <|> plain (Primitive TNumber) <$ keyword "number"
  <|> plain (Primitive TBoolean) <$ keyword "boolean"
  <|> plain (Primitive TTimestamp) <$ keyword "timestamp"

referenceP :: Parser Located
referenceP = do
  keyword "Ref"
  plain . Reference <$> between (symbol "<") (symbol ">") identifier

objectP :: Parser Located
objectP = do
  fields <- between (symbol "{") (symbol "}") (many fieldP)
  pure (Located (Object (map fst fields)) (concatMap snd fields))
  where
    fieldP = do
      isKey <- option False (True <$ keyword "key")
      (name, source) <- locatedIdentifier
      isOptional <- option False (True <$ symbol "?")
      void (symbol ":")
      Located ty ls <- typeExprP
      void (symbol ";")
      pure (FieldExpr name isOptional isKey ty,
        ([name], source) : [(name:p, s) | (p,s) <- ls])

alternativeP :: Parser Located
alternativeP = do
  keyword "alternative"
  (tag, source) <- locatedIdentifier
  branches <- between (symbol "{") (symbol "}") (some branchP)
  pure (Located (Alternative tag (map fst branches)) ((["@tag:" ++ tag], source) : concatMap snd branches))
  where
    branchP = do
      (name, source) <- locatedIdentifier
      void (symbol ":")
      Located ty ls <- typeExprP
      void (symbol ";")
      pure (BranchExpr name ty, (["@branch:" ++ name], source) : [(("@branch:" ++ name):p, s) | (p,s) <- ls])

functionP :: Parser Located
functionP = try $ do
  params <- between (symbol "(") (symbol ")") (parameterP `sepBy1` symbol ",")
  void (symbol "=>")
  Located result ls <- typeExprP
  pure (Located (Function (map fst params) result) (concatMap snd params ++ ls))
  where
    parameterP = do
      (name, source) <- locatedIdentifier
      void (symbol ":")
      Located ty ls <- typeExprP
      pure (ParameterExpr name ty, (["@argument:" ++ name], source) : [(("@argument:" ++ name):p, s) | (p,s) <- ls])

atomP :: Parser Located
atomP = alternativeP <|> referenceP <|> objectP <|> primitiveP
  <|> plain . Literal <$> literalP
  <|> plain . Named <$> identifier
  <|> between (symbol "(") (symbol ")") typeExprP

postfixP :: Parser Located
postfixP = do
  base <- atomP
  suffixes <- many (symbol "[]")
  pure (foldl (\x _ -> wrapped Collection x) base suffixes)

uniqueP :: Parser Located
uniqueP = try $ do
  keyword "unique"
  selectors <- option [] (between (symbol "(") (symbol ")") (identifier `sepBy1` symbol ","))
  wrapped (Unique selectors) <$> postfixP

termP :: Parser Located
termP = functionP <|> uniqueP <|> postfixP

intersectionP :: Parser Located
intersectionP = combined Intersection <$> (termP `sepBy1` symbol "&")

typeExprP :: Parser Located
typeExprP = combined Union <$> (intersectionP `sepBy1` symbol "|")

declarationP :: Parser ((Name, TypeExpr), [SourceLocation])
declarationP = do
  keyword "type"
  (name, source) <- locatedIdentifier
  void (symbol "=")
  Located expr ls <- typeExprP
  void (symbol ";")
  pure ((name, expr), [SourceLocation name p s | (p,s) <- ([], source) : ls])

moduleP :: Parser (Module, [SourceLocation])
moduleP = do
  spaceConsumer
  ds <- many declarationP
  eof
  let names = map (fst . fst) ds
  case duplicates names of
    [] -> pure (Module (M.fromList (map fst ds)), concatMap snd ds)
    d:_ -> fail ("duplicate type declaration " ++ d)
  where
    duplicates xs = [x | (i,x) <- zip [0 :: Int ..] xs, x `elem` take i xs]

parseModuleLocated :: FilePath -> String -> Either String (Module, [SourceLocation])
parseModuleLocated file input = case runParser moduleP file input of
  Left e -> Left (errorBundlePretty e)
  Right m -> Right m

parseModule :: FilePath -> String -> Either String Module
parseModule file = fmap fst . parseModuleLocated file

parseModuleFile :: FilePath -> IO (Either String Module)
parseModuleFile file = parseModule file <$> readFile file

