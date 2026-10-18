module Main (main) where

import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Workbench.Runtime (runRequest)

main :: IO ()
main = B.getContents >>= B.putStr . T.encodeUtf8 . T.pack . runRequest . T.unpack . T.decodeUtf8
