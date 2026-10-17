module OSQL.Timestamp (normalizeTimestamp) where

import Control.Monad (unless)
import Data.Char (isDigit)
import Data.Time.Calendar (fromGregorianValid, addDays, toGregorian)
import Text.Read (readMaybe)

-- Preserve arbitrary fractional precision; calendar arithmetic uses whole seconds.
normalizeTimestamp :: String -> Either String String
normalizeTimestamp input = do
  unless (length input >= 20 && input !! 4 == '-' && input !! 7 == '-'
    && input !! 10 == 'T' && input !! 13 == ':' && input !! 16 == ':') invalid
  year <- number (take 4 input)
  month <- number (take 2 (drop 5 input))
  day <- number (take 2 (drop 8 input))
  hour <- number (take 2 (drop 11 input))
  minute <- number (take 2 (drop 14 input))
  second <- number (take 2 (drop 17 input))
  unless (year >= 1 && year <= 9999 && hour <= 23 && minute <= 59 && second <= 59) invalid
  date <- maybe invalid Right (fromGregorianValid (toInteger year) month day)
  let suffix = drop 19 input
  (fraction, zone) <- case suffix of
    '.':rest -> let (digits, remaining) = span isAsciiDigit rest
                in if null digits then invalid else Right (digits, remaining)
    _ -> Right ("", suffix)
  offset <- case zone of
    "Z" -> Right 0
    sign:h1:h2:':':m1:m2:[] | sign == '+' || sign == '-' -> do
      h <- number [h1,h2]
      m <- number [m1,m2]
      unless (h <= 23 && m <= 59 && zone /= "-00:00") invalid
      pure ((if sign == '-' then negate else id) (h * 3600 + m * 60))
    _ -> invalid
  let (days, seconds) = (hour * 3600 + minute * 60 + second - offset) `divMod` 86400
      (y,mo,d) = toGregorian (addDays (toInteger days) date)
      (h,remaining) = seconds `divMod` 3600
      (mi,se) = remaining `divMod` 60
      kept = reverse (dropWhile (== '0') (reverse fraction))
  pure (pad 4 y ++ "-" ++ pad 2 mo ++ "-" ++ pad 2 d ++ "T"
    ++ pad 2 h ++ ":" ++ pad 2 mi ++ ":" ++ pad 2 se
    ++ (if null kept then "" else '.':kept) ++ "Z")
  where
    invalid = Left ("Invalid timestamp literal " ++ show input)
    number s | not (null s) && all isAsciiDigit s = maybe invalid Right (readMaybe s :: Maybe Int)
             | otherwise = invalid
    isAsciiDigit c = isDigit c && c >= '0' && c <= '9'
    pad n value = let s = show value in replicate (n - length s) '0' ++ s

