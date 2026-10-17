module Application.Files
  ( Files, files, combine, fileList, readScaffold, writeFresh
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Char (isControl, toLower)
import Data.List (nub)
import qualified Data.Map.Strict as M
import System.Directory (doesPathExist, createDirectory, createDirectoryIfMissing)
import System.FilePath ((</>), isAbsolute, splitDirectories, takeDirectory)

newtype Files = Files (M.Map FilePath String) deriving (Eq, Show)

-- Reject ambiguous paths, including case collisions on case-insensitive FSs.
files :: [(FilePath, String)] -> Either String Files
files entries = do
  let names = map fst entries
      folded = map (map toLower) names
  unless (length folded == length (nub folded)) (Left "Generated file paths collide")
  mapM_ valid names
  pure (Files (M.fromList entries))
  where
    valid path = unless
      (not (null path) && not (isAbsolute path) && '\\' `notElem` path
        && ':' `notElem` path && not (any isControl path)
        && all (`notElem` ["", ".", ".."]) (splitDirectories path))
      (Left ("Unsafe generated file path: " ++ show path))

combine :: [Files] -> Either String Files
combine = files . concatMap fileList

fileList :: Files -> [(FilePath, String)]
fileList (Files entries) = M.toAscList entries

-- The scaffold is an explicit input to the pure compiler. These templates
-- contain only invariant runtime/build plumbing, never view/layout decisions.
readScaffold :: FilePath -> IO Files
readScaffold base = do
  entries <- forM paths (\path -> do
    contents <- readFile (base </> path)
    length contents `seq` pure (path,contents))
  either (ioError . userError) pure (files entries)
  where paths =
          [ "package.json", "tsconfig.json", ".gitignore", ".env.example"
          , "scripts/build.mjs", "public/index.html", "public/app.css"
          , "server/runtime.ts", "client/page-runtime.tsx", "README.md" ]

-- No implicit overwrites. Generate into a fresh directory, inspect, then
-- replace/deploy explicitly. Parent directories are not part of the manifest.
writeFresh :: FilePath -> Files -> IO ()
writeFresh destination manifest = do
  exists <- doesPathExist destination
  when exists (ioError (userError "Output directory already exists; refusing to overwrite it"))
  createDirectoryIfMissing True (takeDirectory destination)
  createDirectory destination
  forM_ (fileList manifest) $ \(path,contents) -> do
    let target = destination </> path
    createDirectoryIfMissing True (takeDirectory target)
    writeFile target contents

