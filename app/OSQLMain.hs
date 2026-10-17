module Main (main) where

import OSQL.Parser (parseProgramFile, renderParseError)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  file <- case args of
    [path] -> pure path
    _ -> die "Usage: osql-parse FILE"
  result <- parseProgramFile file
  either (die . renderParseError) print result

