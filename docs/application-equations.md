# From a prepared view to a read-only TypeScript application

This slice adds new types beside the working ontology, labels and PostgreSQL compilers. It does not repurpose `Ontology.Labels.Plan.Shape` and does not change the existing read equations.

## Inputs and outputs

```
PreparedView + technical naming
    -> PageData (technical keys, semantic subjects, types, presence)
PageData + Labeling
    -> Presentation (groups, displays, repeats, conditionals)
Presentation
    -> JSX (closed native tags and expression forms)
PageData + JSX
    -> typed pure React component
PreparedView + endpoint name
    -> Endpoint -> Express module
Pages + endpoints + invariant scaffold
    -> checked Files -> filesystem writer
```

A generated component receives only `data`. It does not fetch or choose a projection. The separate page wrapper sends semantic identifying parameters to its endpoint, validates the technical JSON, and passes the response to the component. The endpoint uses the existing parameterized SQL, not a new traversal implementation.

## Page-data correspondence

`Application.Data` defines:

```haskell
data PageData
  = ScalarData Scalar
  | ObjectData [DataField]
  | ArrayData PageData
  | NullableData PageData

data DataField = DataField
  { dataKey :: String
  , dataSubject :: Property
  , dataPresence :: Presence
  , dataShape :: PageData
  }
```

`dataKey` is the actual technical JSON property. `dataSubject` is the semantic input to the label interpretation. These must not be collapsed: a composed inverse can have a multi-step technical JSON key while its caption is supplied by a local ontology relation.

Scalar subjects retain their ontology address and atom for enum labeling. Terminal references expand only their declared semantic keys; following a reference selects the ordinary target-type fields. No contextual label overrides are introduced.

The whole response includes `null` when the center is not found. This preserves the existing read contract; it does not reinterpret every null as HTTP 404. A nullable field, an absent branch property, an empty array, an empty object and an explicit cutoff remain different descriptions.

## Presentation equations

Let `D` be the page-data description, `L` the labeling interpretation, and `x` a symbolic data expression.

```
P_L(Scalar(s), x) = Display(s, x, printer_L(s))
P_L(Object(fs), x) = Group [Section(label_L(f.subject),
                                  condition(f),
                                  P_L(f.shape, Get(x,f.key))) | f <- fs]
P_L(Array(s), x) = if Empty(x) then Message("No entries")
                  else Repeat(x, e -> P_L(s,e))
P_L(Nullable(s), x) = if Null(x) then Message("No value")
                     else P_L(s,x)
```

An empty object has the explicit message `No selected fields`. This means precisely that its selected payload has no fields, not that the corresponding real-world entity has no properties.

Expressions are `Input`, lexical `Item n`, and `Get expression technicalKey`. Nested loops introduce separate lexical binders. The resulting presentation is finite because the input projection is finite.

Branch-only fields are guarded by their own-property presence in the validated technical response. This works even when the discriminator was not selected. The renderer never reads an unselected discriminator and never compares a raw tag with its English caption.

The initial presentation convention preserves nested groups and uses description lists and ordinary lists. It is deliberately not a cognitive optimizer or a general layout policy. Field captions, finite-value captions and plain scalar printing are separate from technical property access.

## JSX interpretation

```
J(Display(s,x,p)) = <span>{print_p(x)}</span>
J(Group(sections)) = <dl>...labeled sections...</dl>
J(Repeat(xs,e,p)) = <ul>{xs.map(e -> <li>J(p)</li>)}</ul>
J(Conditional(c,a,b)) = c ? J(a) : J(b)
```

The actual representation is `Application.JSX.JSX`, with a closed tag/attribute vocabulary, text nodes, scalar expressions, conditional nodes and repetition. There is no raw JavaScript or raw HTML constructor. User captions are JavaScript string expression literals, never JSX source fragments; returned data is rendered as text. Unicode is decoded as UTF-8 before source emission.

`Application.TypeScript` independently lowers PageData to readonly prop types and specialized boundary validators. Optional branch slots form a safe structural approximation; validators check finite domains, primitive types, required and unexpected properties and branch exclusivity, not all ontology invariants.

Arrays currently use positional React keys for stateless read-only snapshots. Those are NOT semantic identity. Before introducing stateful item controls or editing, add a stable occurrence-key policy. Timestamps are printed as their technical strings; locale/timezone formatting is a future explicit printer.

## Endpoint equations

```
E(name, view) = Endpoint(name, parameters(view), compileTechnicalRead(view))
Express(E) = fixed wrapper around the prepared query and scalar codec
```

`Application.Endpoint` uses `Postgres.Read.compilePrepared`. Parameter order and scalar domains come from the existing PreparedView. The runtime accepts a fixed set of query parameters, rejects missing/extra/repeated/ill-typed inputs, and binds values separately from SQL text.

Reads run in a read-only transaction with a local statement timeout and the CI database role has only SELECT access. The scaffold defaults to loopback. It intentionally does not implement user authentication, row-level authorization, write actions, pagination, or a complete resource-budget policy. Do not expose it with sensitive data before integrating the application access policy.

## File composition

```
Files(app) = Scaffold + Components + Endpoints + PageBindings + SQL + IR
```

`+` is checked union, not last-wins overwrite. Page and endpoint names are validated route/file slugs. The filesystem writer refuses an existing destination. Compilation computes the manifest before writing. File writing is the effectful boundary, not part of the semantic equations.

## Command line

Install GHC with the existing dependencies plus `aeson`, `text`, `bytestring`, `vector`, `directory` and `filepath` (Ubuntu packages `ghc libghc-megaparsec-dev libghc-aeson-dev` provide them).

```sh
mkdir -p /tmp/ontology-app-build
/usr/bin/ghc -O0 -Wall -Werror \
  -isrc \
  -outputdir /tmp/ontology-app-build \
  app/ApplicationMain.hs -o /tmp/ontology-app

/tmp/ontology-app \
  test/fixtures/labels.ontology Root \
  test/fixtures/labels.en.label \
  examples/labels.app.json \
  /tmp/generated-ontology-app
```

The optional final argument supplies the scaffold template directory. `-` instead of the label file selects technical captions. The CLI initially reuses the existing stricter catalog checker (including English-JSON sibling collisions); the frontend API itself does not require unique visible captions. Equal captions attached to different technical keys can be rendered without ambiguity in the data access. This limitation is not a change to the existing checker.

The manifest is a small JSON input frontend, not another view semantics. It lowers to existing ViewSource/Projector types. Page keys are `name`, `title`, `population`, optional `center`, `depth`, `references` (`keys` or `follow`), `direction` (`out`, `in`, `both`), `repeat`, and `fields`. The `fields` shorthand is the existing primitive field matcher throughout the projection, not an arbitrary selection DSL. Richer composed views remain available via the Haskell API. Unknown manifest keys are rejected.

The generated README contains provisioning/build instructions. Do not run the generated CREATE TABLE script against an existing schema. npm's generated lockfile must be retained for repeatable installations.

## Verification target

```
textObservation(React(J(P)), data) = interpretPresentation(P, data)
endpointResult(view, parameters) = existingTechnicalRead(view, parameters)
```

The reference interpreter is Haskell and operates on actual PostgreSQL JSON. It does not execute JSX or parse generated JavaScript. Tests compare its ordered caption/value/message observations against React server rendering and Chromium, and independently verify the Express result against the legacy SQL oracle. These are executable regression checks, not a universal correctness proof or a proof about human comprehension.

The test matrix includes nested records, terminal/expanded references, inverse relations, maps, set members, enums, optional values, null centers, empty arrays/objects, alternatives with and without a selected discriminator, cutoffs, nested lexical binders, Unicode and hostile text, invalid request shapes and SQL-injection strings. CI also typechecks the generated source and builds client/server bundles.

