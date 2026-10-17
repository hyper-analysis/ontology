# Small configurable projectors

```text
checked ontology -> semantic graph -> lazy centered schema
                                             |
                                    explicit Projector
                                             |
                                      finite Projection
                                             |
                                [later: SQL query -> JSON]
```

`Ontology.Projection` interprets configuration. It does not choose the best
configuration. Center choice and projection choice are replaceable design
policies; neither is an ontology law. A future AI can propose `View` values
without becoming part of the deterministic compiler.

## Configuration

```haskell
data Projector = Projector
  { maximumDepth :: Int
  , directions :: Directions
  , references :: References
  , repetition :: Repetition
  , edgeSelection :: EdgeSelection
  }

data View = View
  { viewName :: String
  , viewCenter :: Address
  , viewProjector :: Projector
  }

project     :: Projector -> Centered -> Either String Projection
projectView :: World -> View -> Either String Projection
```

Depth is always non-negative and bounded. It counts connections (one primitive
edge per connection in our current centered schema). It is not a database row
limit or a guarantee that a large depth is cheap.

Directions are `OutgoingOnly`, `IncomingOnly`, or `Both`. Reference handling is
`FollowReferences` or `ReferenceLinks`: the latter retains reference occurrences
but does not cross reference edges, in either direction.

Repetition is `AllowRepeats` or `StopAtRepeatedAddress`. Repetition is tested
against the current route, not globally across sibling branches. This is a
SCHEMA-address heuristic: revisiting `Person` does not prove that two runtime
persons are equal. It may intentionally stop a manager chain of distinct people.

Edge selection is `AllEdges`, `OnlyEdges [Match]`, or `ExceptEdges [Match]`.
`Through primitive` matches a relation containing that primitive; `To address`
matches its oriented destination. Lists are ORed. Selection is applied at every
expanded node; selecting a deep destination does not automatically select the
route to reach it. Include the intermediate edges or center closer to the target.
An unmatched primitive filter is allowed to select nothing; an explicit unknown
`To` address is rejected by `projectView`.

## Output and laziness

The projection retains each selected point's address, kind, key and guards.
Each followed connection retains the complete typed `Relation`, including its
orientation and edge metadata. Unselected connections are explicitly marked
`NotSelected` or `ReferenceBoundary` and have no child payload. A consumer must
not turn these omissions into SQL reads.

`DepthLimit` and `RepeatedAddress` mark stopped nodes. They do not mean that no
further information exists. Disabled directions are not enumerated. Depth zero
never evaluates the outgoing or incoming connection lists; omitted connections
never evaluate their targets. The interpreter does not modify or consume the
underlying lazy centered value.

The full unfiltered configuration with repeats allowed is regression-tested
against `observeDepth`. The older observer and the centering definition are
unchanged.

## Replaceable presets and views

`forwardValue n` follows outgoing owned structure and keeps references terminal.
`neighborhood n` follows both directions and stops repeated route addresses.
`incomingContext n` explores incoming relations only, with the same repeat rule.

`examples/TutoringViews.hs` defines four fixtures, not final UX decisions:

| View | Center | Choice |
| --- | --- | --- |
| student-summary | Person's Student branch | First and last name only |
| student-value | Person's Student branch | Outgoing structure, depth 4, references terminal |
| person-neighborhood | Person | Both directions, depth 3, route repetition stopped |
| school-year-incoming | SchoolYear | Incoming relations, depth 2 |

From `ontology-language`:

```bash
cabal run ontology-view -- --list
cabal run ontology-view -- examples/tutoring-company.ontology TutoringCompany student-summary
cabal run ontology-view -- examples/tutoring-company.ontology TutoringCompany student-value 2
cabal test projection-test
```

The CLI prints a finite SCHEMA description, not records or result JSON. Tests
also vary depths 0 through 3 for every fixture. The SQL storage pipeline is left
unchanged. Nested JSON query compilation, pagination, runtime instance binding,
authorization, aliases and automatic choice/ranking of views are separate work.
There is intentionally no LLM integration or additional configuration parser yet.

