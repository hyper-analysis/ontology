-- The catalog is a checked, ontology-local linguistic annotation.
-- Views may ask for labels, but they never create label identities.
module Ontology.Labels
  ( module Ontology.Labels.Types, module Ontology.Labels.Parser
  , requirementsFor, checkLabels, prepareLabeling, exportTemplate
  ) where

import Data.Char (isSpace)
import Data.List (nub, sort)
import qualified Data.Map.Strict as M
import Ontology.Center.Graph
import Ontology.Labels.Types
import Ontology.Labels.Adapter (localRelationship)
import Ontology.Labels.Parser
import Ontology.Labels.Plan
import Ontology.Views (PreparedView(..))
import qualified Ontology.Relational as R
import qualified Ontology.Syntax as O

data Assignment = Assignment
  { assignmentKey :: String
  , assignmentValue :: String
  , assignmentLocation :: Location
  , assignmentSpecific :: Bool
  }

data Focus = NodeFocus Address Bool

diagnostic :: Severity -> String -> String -> String -> Maybe Location -> Diagnostic
diagnostic = Diagnostic

plans :: World -> [PreparedView] -> ([Shape], [Diagnostic])
plans graph views =
  ([s | Right s <- results], [d | Left d <- results])
  where
    results =
      [ case labelShape graph (preparedProjection view) of
          Right s -> Right s
          Left message -> Left (diagnostic Error "invalid-view" (preparedName view) message Nothing)
      | view <- views
      ]

requirementsFor :: World -> [PreparedView] -> Either [Diagnostic] [Requirement]
requirementsFor graph views = case plans graph views of
  (shapes, []) -> Right (uniqueRequirements shapes)
  (_, errors) -> Left errors

uniqueRequirements :: [Shape] -> [Requirement]
uniqueRequirements =
  M.elems . M.fromList . map (\r -> (requirementId r, r)) . concatMap requirements

checkLabels :: O.Ontology -> World -> [PreparedView] -> Catalog -> LabelReport
checkLabels ontology graph views catalog = fst (analyze ontology graph views catalog)

prepareLabeling :: O.Ontology -> World -> [PreparedView] -> Maybe Catalog -> Either [Diagnostic] Labeling
prepareLabeling _ graph views Nothing =
  let (_, errors) = plans graph views
  in if null errors then Right technical else Left (sort (nub errors))
prepareLabeling ontology graph views (Just catalog) =
  let (report, result) = analyze ontology graph views catalog
      errors = filter ((== Error) . diagnosticSeverity) (labelDiagnostics report)
  in if null errors then Right result else Left errors

analyze :: O.Ontology -> World -> [PreparedView] -> Catalog -> (LabelReport, Labeling)
analyze ontology graph views catalog@(Catalog language _) = (report, labeling)
  where
    (shapes, shapeErrors) = plans graph views
    required = uniqueRequirements shapes
    requiredIds = map requirementId required
    (assignments, resolutionErrors) = resolveCatalog ontology graph catalog
    known = nub (knownIds graph)

    grouped = M.fromListWith (flip (++))
      [(assignmentKey a, [a]) | a <- assignments]

    winner xs =
      let specific = filter assignmentSpecific xs
          common = filter (not . assignmentSpecific) xs
      in case specific of
          [a] -> Just a
          [] -> case common of [a] -> Just a; _ -> Nothing
          _ -> Nothing

    effective = M.fromList
      [ (key, assignmentValue a)
      | (key, xs) <- M.toAscList grouped
      , Just a <- [winner xs]
      , key `elem` known
      , not (all isSpace (assignmentValue a))
      ]

    domains = M.fromList
      [(siteAddress s, finiteValues atom) | s <- sites graph, Atomic atom <- [siteKind s]]

    labeling = Labeling
      (\property -> localProperty property >>= lookupLabel . propertyId)
      (\at -> mapM
        (\literal -> (\caption -> (literal,caption)) <$> lookupLabel (choiceId at literal))
        (M.findWithDefault [] at domains))

    localProperty property = case property of
      Relationship relation form -> localRelationship relation form
      _ -> Right property

    lookupLabel key =
      maybe (Left ("Unchecked or missing label: " ++ key)) Right (M.lookup key effective)

    malformed =
      [ diagnostic Error "unknown-subject" (assignmentKey a)
          "No such ontology-local label subject" (Just (assignmentLocation a))
      | a <- assignments, assignmentKey a `notElem` known
      ]
      ++
      [ diagnostic Error "empty-text" (assignmentKey a)
          "Supply nonblank English wording" (Just (assignmentLocation a))
      | a <- assignments, all isSpace (assignmentValue a)
      ]
      ++ concat
      [ duplicateProblems key xs
      | (key,xs) <- M.toAscList grouped
      ]

    duplicateProblems key xs =
      let specific = filter assignmentSpecific xs
          common = filter (not . assignmentSpecific) xs
          problem kind ys =
            [ diagnostic Error "duplicate" key
                ("The same " ++ kind ++ " label is assigned " ++ show (length ys)
                  ++ " times; keep exactly one definition")
                (Just (assignmentLocation (head ys)))
            | length ys > 1
            ]
      in problem "specific" specific ++ problem "common" common

    missing =
      [ diagnostic Error "missing" key "Required by a declared view" Nothing
      | key <- requiredIds, M.notMember key effective
      ]

    unused =
      [ diagnostic Warning "unused" (assignmentKey a)
          "Valid ontology label not used by the selected views; it may be retained"
          (Just (assignmentLocation a))
      | a <- assignments
      , assignmentKey a `elem` known
      , assignmentKey a `notElem` requiredIds
      ]

    localeErrors =
      [ diagnostic Error "language" language
          "This first label compiler supports language en" Nothing
      | language /= "en"
      ]

    report = LabelReport required
      (sort (nub (localeErrors ++ shapeErrors ++ resolutionErrors
        ++ malformed ++ missing ++ unused ++ concatMap (collisions labeling) shapes)))

knownIds :: World -> [String]
knownIds graph =
  [ propertyId (Relationship r form)
  | edge <- edges graph
  , r <- [forward edge, inverse (forward edge)]
  , authored (edgePrimitive edge)
  , form <- [Singular,Plural]
  ]
  ++
  [ propertyId (KeyField (siteAddress s) form)
  | s <- sites graph, keySite (siteAddress s), form <- [Singular,Plural]
  ]
  ++
  [ titleId (siteAddress s) form
  | s <- sites graph, form <- [Singular,Plural]
  ]
  ++
  [ choiceId (siteAddress s) value
  | s <- sites graph, Atomic atom <- [siteKind s], value <- finiteValues atom
  ]
  ++
  [ propertyId (Structural (population "") w) | w <- allWrappers ]
  where
    authored primitive = case primitive of
      Field _ -> True
      Argument _ -> True
      Discriminant _ -> True
      Variant _ _ -> True
      _ -> False
    keySite at = case reverse (addressPath at) of
      R.Field _:_ -> True
      R.Argument _:_ -> True
      _ -> False

-- Named checked nodes, not equal shapes or literal sets, determine reuse.
-- References do not unfold here. Crossing Ref<T> in a view later resolves
-- against T's ordinary population labels rather than a ref-local namespace.
occurrences :: O.Ontology -> World -> [(Address, O.NodeId)]
occurrences ontology graph = concat
  [ walk (siteAddress s) ident
  | s <- sites graph
  , null (addressPath (siteAddress s))
  , Just ident <- [M.lookup (addressPopulation (siteAddress s)) (O.namedNodes ontology)]
  ]
  where
    walk at ident = (at,ident) : case M.lookup ident (O.nodes ontology) of
      Just (O.Record fs) ->
        concat [walk (within at [R.Field (O.fieldName f)]) (O.fieldType f) | f <- fs]
      Just (O.Many child) -> walk (within at [R.Elements]) child
      Just (O.Distinct _ child) -> walk (within at [R.Elements]) child
      Just (O.FunctionNode ps child) ->
        let entry = within at [R.Entries]
        in walk entry child
          ++ concat
            [walk (within entry [R.Argument (O.parameterName p)]) (O.parameterType p) | p <- ps]
      Just (O.AlternativeNode tag bs) ->
        concat
          [walk (within at [R.Branch tag (O.branchName b)]) (O.branchType b) | b <- bs]
      _ -> []

resolveCatalog :: O.Ontology -> World -> Catalog -> ([Assignment], [Diagnostic])
resolveCatalog ontology graph (Catalog _ declarations) = combine (map declaration declarations)
  where
    occurrenceIndex = occurrences ontology graph

    combine xs = (concatMap fst xs, concatMap snd xs)

    bad at subject message =
      ([],[diagnostic Error "invalid-subject" subject message (Just at)])

    emit specific at key value =
      ([Assignment key value at specific],[])

    emitForms at makeKey form value = case form of
      Just one -> emit True at (makeKey one) value
      Nothing -> combine [emit False at (makeKey one) value | one <- [Singular,Plural]]

    declaration (System _ assignments) = combine
      [ case [w | w <- allWrappers, wrapperName w == key] of
          [w] -> emit True at (propertyId (Structural (population "") w)) value
          _ -> bad at key
            "Unknown system wrapper; expected mapKey, mapValue, contextValue, or cutoff"
      | (at,key,value) <- assignments
      ]

    declaration (Labels at name body) = case M.lookup name (O.namedNodes ontology) of
      Nothing -> bad at name "Unknown named ontology type"
      Just ident -> case nub [a | (a,i) <- occurrenceIndex, i == ident] of
        [] -> ([],[diagnostic Warning "unused-type" name
              "Type has no reachable occurrences in this world" (Just at)])
        locations -> combine [items (NodeFocus a True) False body | a <- locations]

    items focus backwards = combine . map (item focus backwards)

    item focus backwards (Caption at form value) =
      caption focus at backwards form value

    item focus _ (Inverse at body)
      | all isCaption body = items focus True body
      | otherwise = bad at "inverse"
          "An inverse block only supplies labels for this ontology relation"
      where
        isCaption (Caption _ _ _) = True
        isCaption _ = False

    item (NodeFocus point _) _ (Choice at value display) =
      case siteAt graph point of
        Right s -> case siteKind s of
          Atomic atom
            | value `elem` finiteValues atom ->
                emit True at (choiceId point value) display
          _ -> bad at (addressText point ++ " " ++ literalText value)
                "Value is not in this finite scalar choice domain"
        Left message -> bad at (addressText point) message

    item (NodeFocus point _) _ (Nested at step body) =
      case matching point step of
        Right edge -> items (NodeFocus (edgeTarget edge) False) False body
        Left message -> bad at (addressText point) message

    caption (NodeFocus point root) at backwards form value
      | root || null (addressPath point) =
          if backwards
            then bad at (addressText point)
              "A type title has no inverse; annotate one of its relations"
            else emitForms at (titleId point) form value
      | otherwise =
          case [e | e <- incomingAt graph point, not (isReference e)] of
            [edge] ->
              let relation = if backwards then inverse (forward edge) else forward edge
                  relationAssignments =
                    emitForms at (\one -> propertyId (Relationship relation one)) form value
                  branchAssignments = case (backwards, edgePrimitive edge, form) of
                    (False, Variant tag branch, Nothing) ->
                      emit True at
                        (choiceId (within (edgeSource edge) [R.TagName tag]) (O.TextLiteral branch))
                        value
                    (False, Variant tag branch, Just Singular) ->
                      emit True at
                        (choiceId (within (edgeSource edge) [R.TagName tag]) (O.TextLiteral branch))
                        value
                    _ -> ([],[])
              in combine [relationAssignments, branchAssignments]
            _ -> bad at (addressText point)
                  "No unique owned ontology relation at this location"

    isReference edge = case edgePrimitive edge of
      Reference _ -> True
      _ -> False

    matching point step =
      case filter matches (outgoingAt graph point) of
        [edge] -> Right edge
        _ -> Left ("No unique " ++ show step ++ " below this ontology location")
      where
        matches edge = case (step,edgePrimitive edge) of
          (FieldStep x,Field y) -> x == y
          (ItemsStep,Elements _) -> True
          (EntriesStep,Entries _) -> True
          (ArgumentStep x,Argument y) -> x == y
          (TagStep x,Discriminant y) -> x == y
          (BranchStep x,Variant _ y) -> x == y
          _ -> False

-- Template export is deliberately not a second authoring syntax. The machine
-- interface is the JSON requirements report; this file remains ontology-shaped.
exportTemplate :: [Requirement] -> String
exportTemplate rs =
  "language en;\n\n"
  ++ "// Required ontology-local labels (fill them in labels Type { ... } blocks):\n"
  ++ concat ["// " ++ requirementId r ++ "\n" | r <- rs]

