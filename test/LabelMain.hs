module Main (main) where

import Control.Monad (unless, forM_)
import Data.List (intercalate, isPrefixOf, nub)
import qualified Data.Map.Strict as M
import Ontology.Check (checkOntology)
import Ontology.Parser (parseModuleFile)
import Ontology.Center.Lazy (center)
import qualified Ontology.Center.Graph as G
import qualified Ontology.Relational as R
import qualified Ontology.Postgres as P
import qualified Ontology.Projection as V
import qualified Ontology.Views as W
import qualified Ontology.Read as I
import qualified Ontology.Labels as L
import qualified Postgres.Read as Read
import qualified Postgres.Physical as Physical
import qualified SQL.Syntax as SQL
import qualified SQL.Render as Render
import System.Exit (die)

right :: Either String a -> IO a
right = either die pure

checked :: Either [L.Diagnostic] a -> IO a
checked = either (die . L.renderReport . L.LabelReport []) pure

assert :: Bool -> String -> IO ()
assert ok message = unless ok (die message)

name :: String -> String
name s = "\"" ++ concatMap (\c -> if c == '"' then "\"\"" else [c]) s ++ "\""

text :: String -> String
text s = "E'" ++ concatMap escape s ++ "'"
  where
    escape '\'' = "''"
    escape '\\' = "\\\\"
    escape c = [c]

f :: String -> R.Segment
f = R.Field

only :: Int -> [G.Primitive] -> V.Projector
only depth ps = (V.forwardValue depth) { V.edgeSelection = V.OnlyEdges (map V.Through ps) }

sources :: [W.ViewSource]
sources =
  [ view "all" [] (V.forwardValue 6)
  , view "summary" [] (only 1 (map G.Field ["code","name","status","other","rank","flag","optional"]))
  , view "manager" [field "manager"] (V.forwardValue 0)
  , view "manager_full" [field "manager"]
      ((only 2 [G.Reference "Person",G.Field "code",G.Field "name"]) { V.references = V.FollowReferences })
  , view "pair" [field "pair"] (V.forwardValue 0)
  , view "first" [field "first"] (V.forwardValue 2)
  , view "second" [field "second"] (V.forwardValue 2)
  , view "tags" [] (only 3 [G.Field "tags",G.Elements R.DistinctWhole])
  , view "tag_values" [field "tags"] (V.forwardValue 3)
  , view "work" [field "work"] (V.forwardValue 4)
  , view "score" [field "work",W.CenterEntries,field "score"] (V.forwardValue 0)
  , view "contact" [field "contacts",W.CenterElements] (V.forwardValue 2)
  , view "choice" [field "choice"] (V.forwardValue 4)
  , view "active" [field "choice",W.CenterBranch 0] (V.forwardValue 3)
  , view "tag" [field "choice",W.CenterTag] (V.forwardValue 0)
  , view "name_context" [field "name"]
      ((V.neighborhood 2) { V.edgeSelection = V.OnlyEdges (map V.Through [G.Field "name",G.Field "code"]) })
  , view "cutoff" [] (V.forwardValue 0)
  ]
  where
    view n = W.ViewSource n "Person"
    field = W.CenterField

inverseView :: G.World -> IO W.PreparedView
inverseView graph = do
  let target = G.population "Person"
      source = G.within target [f "manager"]
  edge <- case [e | e <- G.outgoingAt graph source, G.edgeTarget e == target] of
    [e] -> pure e
    _ -> die "Expected manager reference"
  path <- right (G.ownerRoute graph source >>= \r -> G.compose r (G.forward edge))
  let relation = G.inverse path
  base <- right (W.prepareView graph (W.ViewSource "inverse_manager" "Person" [] (V.forwardValue 0)))
  child <- right (center graph target >>= V.project (only 1 [G.Field "code",G.Field "name"]))
  pure base { W.preparedProjection = (W.preparedProjection base)
    { V.projectedExpansion = V.Expanded [] [V.Followed relation child] } }

mapTexts :: (String -> String) -> L.Catalog -> L.Catalog
mapTexts change (L.Catalog language ds) = L.Catalog language (map declaration ds)
  where
    declaration (L.Labels at t body) = L.Labels at t (map item body)
    declaration (L.System at entries) = L.System at [(p,k,change v) | (p,k,v) <- entries]
    item (L.Caption at form value) = L.Caption at form (change value)
    item (L.Inverse at body) = L.Inverse at (map item body)
    item (L.Choice at literal value) = L.Choice at literal (change value)
    item (L.Nested at step body) = L.Nested at step (map item body)

replace :: String -> String -> L.Catalog -> L.Catalog
replace old new = mapTexts (\s -> if s == old then new else s)

-- Ignore only payload names and finite display CASEs. All FROM/WHERE/join/key
-- ordering clauses, including those of nested selectors, must stay identical.
data QuerySkeleton
  = ReadSkeleton String String SQL.Expr [SQL.Value] [(String,String)]
  | GeneralSkeleton SQL.Query
  deriving (Eq, Show)
skeleton :: SQL.Query -> [QuerySkeleton]
skeleton (SQL.ValueQuery v) = payload v
skeleton (SQL.Query value table alias predicate ordering joins) =
  ReadSkeleton table alias predicate ordering joins : payload value
skeleton query@SQL.SelectQuery{} = [GeneralSkeleton query]

payload :: SQL.JsonExpr -> [QuerySkeleton]
payload (SQL.JsonScalar _) = []
payload (SQL.JsonObject fs) = concatMap (payload . snd) fs
payload (SQL.JsonArray q) = skeleton q
payload (SQL.JsonOne q) = skeleton q
payload (SQL.JsonNullable _ v) = payload v
payload (SQL.JsonCase _ a b) = payload a ++ payload b
payload (SQL.JsonMerge vs) = concatMap payload vs
payload SQL.JsonNull = []

column :: P.PgTable -> R.Path -> IO String
column t path = maybe (die ("Missing column " ++ show path)) pure (lookup path (P.pgBindings t))

tableAt :: P.PgSchema -> P.SemanticOrigin -> IO P.PgTable
tableAt schema at = do
  t <- right (P.tableForValue schema at)
  assert (P.pgValueOrigin t == at) "Expected exact fixture table"
  pure t

rootId :: P.PgSchema -> String -> R.Path -> String -> IO String
rootId schema pop path value = do
  t <- tableAt schema (pop,[])
  c <- column t path
  pure ("(SELECT id FROM " ++ name (P.pgTableName t) ++ " WHERE " ++ name c ++ " = " ++ value ++ ")")

insertRow :: P.PgSchema -> P.SemanticOrigin -> [(R.Path,String)] -> [(R.Path,Bool)] -> [(String,String)] -> IO ()
insertRow schema at values flags physical = do
  t <- tableAt schema at
  pairs <- mapM (\(path,v) -> do c <- column t path; pure (c,v)) values
  markers <- mapM (\(path,v) -> do
    c <- maybe (die "Missing presence") pure (lookup path (P.pgPresenceBindings t))
    pure (c,if v then "true" else "false")) flags
  let supplied = M.fromList (pairs ++ markers ++ physical)
  fields <- mapM (fill supplied) [c | c <- P.pgColumns t, not (P.pgColumnGenerated c)]
  putStrLn ("INSERT INTO " ++ name (P.pgTableName t) ++ " (" ++ intercalate "," (map (name . fst) fields)
    ++ ") VALUES (" ++ intercalate "," (map snd fields) ++ ");")
  where
    fill supplied c = case M.lookup (P.pgColumnName c) supplied of
      Just v -> pure (P.pgColumnName c,v)
      Nothing | "__present_" `isPrefixOf` P.pgColumnName c -> pure (P.pgColumnName c,"false")
              | P.pgColumnNullable c -> pure (P.pgColumnName c,"NULL")
              | otherwise -> die ("Omitted fixture column " ++ P.pgColumnName c)

fixture :: P.PgSchema -> IO ()
fixture schema = do
  putStrLn "BEGIN;"
  insertRow schema ("Pair",[]) [([f "identity",f "region"],text "EU"),([f "identity",f "serial"],"17")] [] []
  pair <- rootId schema "Pair" [f "identity",f "region"] (text "EU")
  forM_ [("P1","Alice"),("P2","Bob")] $ \(code,display) -> do
    let active = code == "P1"
    insertRow schema ("Person",[])
      ([([f "code"],text code),([f "name"],text display),([f "status"],text (if active then "active" else "paused"))
      ,([f "other"],text "active"),([f "rank"],if active then "1" else "2"),([f "flag"],if active then "true" else "false")
      ,([f "pair"],pair),([f "first",f "city"],text "Paris"),([f "second",f "city"],text "Lyon")
      ,([f "choice",R.TagName "state"],text (if active then "Active" else "Empty"))]
        ++ [([f "optional"],text "paused") | active])
      [([f "pair"],True),([f "optional"],active)] []
  p1 <- rootId schema "Person" [f "code"] (text "P1")
  p2 <- rootId schema "Person" [f "code"] (text "P2")
  person <- tableAt schema ("Person",[])
  manager <- column person [f "manager"]
  codeColumn <- column person [f "code"]
  flag <- maybe (die "Missing manager presence") pure (lookup [f "manager"] (P.pgPresenceBindings person))
  putStrLn ("UPDATE " ++ name (P.pgTableName person) ++ " SET " ++ name manager ++ " = " ++ p2
    ++ ", " ++ name flag ++ " = true WHERE " ++ name codeColumn ++ " = " ++ text "P1" ++ ";")
  insertRow schema ("Person",[f "choice",R.Branch "state" "Active"])
    [([f "note"],text "Hello"),([f "contact"],p2)] [] [("id",p1)]
  insertRow schema ("Person",[f "choice",R.Branch "state" "Empty"]) [] [] [("id",p2)]
  forM_ ["omega","alpha"] $ \tag ->
    insertRow schema ("Person",[f "tags",R.Elements]) [([],text tag)] [] [("id",p1)]
  insertRow schema ("Person",[f "contacts",R.Elements])
    [([f "kind"],text "active"),([f "value"],text "a@x")] [] [("id",p1)]
  insertRow schema ("Person",[f "work",R.Entries])
    [([R.Argument "year"],"2026"),([f "score"],"17")] [] [("id",p1)]
  putStrLn "COMMIT;"

-- Case name, semantic parameters, technical JSON, English presentation JSON.
cases :: [(String,[I.Scalar],String,String)]
cases =
  [ ("summary",[s "P1"],"{\"code\":\"P1\",\"name\":\"Alice\",\"status\":\"active\",\"other\":\"active\",\"rank\":1,\"flag\":true,\"optional\":\"paused\"}",
      "{\"Code\":\"P1\",\"Name\":\"Alice\",\"Status\":\"Active\",\"Other status\":\"Running\",\"Rank\":\"First\",\"Flag\":\"Enabled\",\"Optional status\":\"Paused\"}")
  , ("summary",[s "P2"],"{\"code\":\"P2\",\"name\":\"Bob\",\"status\":\"paused\",\"other\":\"active\",\"rank\":2,\"flag\":false,\"optional\":null}",
      "{\"Code\":\"P2\",\"Name\":\"Bob\",\"Status\":\"Paused\",\"Other status\":\"Running\",\"Rank\":\"Second\",\"Flag\":\"Disabled\",\"Optional status\":null}")
  , ("summary",[s "missing"],"null","null")
  , ("manager",[s "P1"],"{\"code\":\"P2\"}","{\"Code\":\"P2\"}")
  , ("manager",[s "P2"],"null","null")
  , ("manager_full",[s "P1"],"{\"code\":\"P2\",\"name\":\"Bob\"}","{\"Code\":\"P2\",\"Name\":\"Bob\"}")
  , ("pair",[s "P1"],"{\"identity\":{\"region\":\"EU\",\"serial\":17}}","{\"Identity\":{\"Region\":\"EU\",\"Serial\":17}}")
  , ("first",[s "P1"],"{\"city\":\"Paris\"}","{\"City\":\"Paris\"}")
  , ("second",[s "P1"],"{\"city\":\"Lyon\"}","{\"City\":\"Lyon\"}")
  , ("tags",[s "P1"],"{\"tags\":[\"alpha\",\"omega\"]}","{\"Tags\":[\"alpha\",\"omega\"]}")
  , ("tags",[s "P2"],"{\"tags\":[]}","{\"Tags\":[]}")
  , ("tag_values",[s "P1"],"[\"alpha\",\"omega\"]","[\"alpha\",\"omega\"]")
  , ("work",[s "P1"],"[{\"key\":{\"year\":2026},\"value\":{\"score\":17}}]","[{\"Key\":{\"Year\":2026},\"Details\":{\"Score\":17}}]")
  , ("score",[s "P1",n 2026],"17","17")
  , ("score",[s "P1",n 1999],"null","null")
  , ("contact",[s "P1",s "active",s "a@x"],"{\"kind\":\"active\",\"value\":\"a@x\"}","{\"Channel\":\"Active\",\"Value\":\"a@x\"}")
  , ("choice",[s "P1"],"{\"state\":\"Active\",\"Active\":{\"note\":\"Hello\",\"contact\":{\"code\":\"P2\"}}}","{\"Status\":\"Enrolled\",\"Enrolled\":{\"Note\":\"Hello\",\"Contact\":{\"Code\":\"P2\"}}}")
  , ("choice",[s "P2"],"{\"state\":\"Empty\",\"Empty\":{}}","{\"Status\":\"No enrollment\",\"No enrollment\":{}}")
  , ("active",[s "P1"],"{\"note\":\"Hello\",\"contact\":{\"code\":\"P2\"}}","{\"Note\":\"Hello\",\"Contact\":{\"Code\":\"P2\"}}")
  , ("active",[s "P2"],"null","null")
  , ("tag",[s "P1"],"\"Active\"","\"Enrolled\"")
  , ("name_context",[s "P1"],"{\"value\":\"Alice\",\"^name\":{\"code\":\"P1\",\"name\":\"Alice\"}}","{\"Observed value\":\"Alice\",\"Owner\":{\"Code\":\"P1\",\"Name\":\"Alice\"}}")
  , ("cutoff",[s "P1"],"{\"$cutoff\":\"DepthLimit\"}","{\"Truncated\":\"DepthLimit\"}")
  , ("inverse_manager",[s "P2"],"{\"^Person.manager/^manager\":[{\"code\":\"P1\",\"name\":\"Alice\"}]}","{\"People managed\":[{\"Code\":\"P1\",\"Name\":\"Alice\"}]}")
  ]
  where
    s = I.StringValue
    n = I.NumberValue

main :: IO ()
main = do
  parsed <- parseModuleFile "test/fixtures/labels.ontology"
  ontology <- right (parsed >>= checkOntology "Root")
  meaning <- right (R.relational "Root" ontology)
  schema <- right (P.postgres meaning)
  graph <- right (G.world "Root" ontology)
  basic <- mapM (right . W.prepareView graph) sources
  backwards <- inverseView graph
  let views = basic ++ [backwards]
  catalog <- checked =<< L.parseLabelsFile "test/fixtures/labels.en.label"
  labels <- checked (L.prepareLabeling ontology graph views (Just catalog))
  rawLabels <- checked (L.prepareLabeling ontology graph views Nothing)
  let report c = L.checkLabels ontology graph views c
      errors c = [d | d <- L.labelDiagnostics (report c), L.diagnosticSeverity d == L.Error]
      hasCollision c = any ((== "collision") . L.diagnosticCode) (errors c)
  assert (null (errors catalog)) "Valid English catalog rejected"
  assert (hasCollision (replace "Code" "Name" catalog)) "Sibling collision not found"
  assert (hasCollision (replace "Details" "Key" catalog)) "Map wrapper collision not found"
  assert (hasCollision (replace "Owner" "Observed value" catalog)) "Context collision not found"
  assert (hasCollision (replace "Enrolled" "Status" catalog)) "Merged alternative/common-field collision not found"
  assert (null (errors (replace "No enrollment" "Enrolled" catalog))) "Exclusive branches must be allowed to share a caption"
  let missing = report (L.Catalog "en" [])
  assert (length [() | d <- L.labelDiagnostics missing, L.diagnosticCode d == "missing"] == length (L.labelRequirements missing))
    "The checker must report every missing requirement"
  broken <- checked (L.parseLabels "broken.label" (unlines
    ["language en;"
    ,"labels Ghost { name { = \"Ghost\"; } }"
    ,"labels Person { name { = \"\"; = \"Repeated\"; } }"
    ,"labels Status { case \"unknown\" = \"Unknown\"; }" ]))
  let codes = nub (map L.diagnosticCode (errors broken))
  assert (all (`elem` codes) ["invalid-subject","empty-text","duplicate","missing"])
    ("Nonexhaustive diagnostics: " ++ show codes)
  case L.parseLabels "syntax.label" "language en; labels Person { name { singular = 12; plural = 34; } }" of
    Left ds -> assert (length ds >= 2) "Syntax recovery should report independent malformed entries"
    Right _ -> die "Malformed label strings accepted"
  required <- checked (L.requirementsFor graph views)
  _ <- checked (L.parseLabels "template.label" (L.exportTemplate required))
  forM_ views $ \view -> do
    raw <- right (Read.compilePrepared meaning schema view)
    rawExplicit <- right (Read.compilePreparedWith rawLabels meaning schema view)
    english <- right (Read.compilePreparedWith labels meaning schema view)
    assert (raw == rawExplicit) "No-catalog interpretation changed legacy query AST"
    assert (skeleton raw == skeleton english)
      "Labeling changed a selector, predicate, or parameter binding"
  putStrLn "CREATE SCHEMA label_equations; SET search_path TO label_equations;"
  putStr (Render.renderProgram (Physical.program schema))
  fixture schema
  forM_ [("raw_",rawLabels),("en_",labels)] $ \(prefix,interpretation) ->
    forM_ views $ \view -> do
      query <- right (Read.compilePreparedWith interpretation meaning schema view)
      let key = prefix ++ W.preparedName view
      putStr (Render.renderPrepared key (Read.parameterSqlTypes view) query)
      putStrLn (Render.renderStatement (SQL.CreateReadFunction ("fn_" ++ key) (Read.parameterSqlTypes view) query))
  forM_ cases $ \(viewName,args,rawExpected,englishExpected) -> do
    view <- case filter ((== viewName) . W.preparedName) views of
      [v] -> pure v
      _ -> die "Unknown fixture view"
    _ <- right (I.instantiateView view args)
    forM_ [("raw_",rawExpected),("en_",englishExpected)] $ \(prefix,expected) -> do
      let key = prefix ++ viewName
          actualArgs = "(" ++ intercalate "," (map scalar args) ++ ");"
      emit (key ++ " prepared") expected ("EXECUTE " ++ name key ++ actualArgs)
      emit (key ++ " function") expected ("SELECT " ++ name ("fn_" ++ key) ++ actualArgs)
  where
    emit label expected command = do
      putStrLn ("SELECT jsonb_build_object('case', " ++ text label ++ ", 'expected', " ++ text expected ++ "::jsonb);")
      putStrLn command
    scalar (I.StringValue s) = text s
    scalar (I.NumberValue n) = show (fromRational n :: Double)
    scalar (I.BooleanValue b) = if b then "true" else "false"
    scalar (I.TimestampValue t) = text (show t)

