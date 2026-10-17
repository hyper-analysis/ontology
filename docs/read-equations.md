# Read equations

This documents the prepared-view frontend. The general, view-independent target
AST and storage resolver are described in [SQL backend](sql-backend.md).

The implementation is in `Postgres.Read`. A `Scope` contains SQL variables and
semantic addresses, never fetched data. A `Selection` is a value describing new
row binders and predicates relative to that scope. `Traversal Direction Edge`
remains the only semantic relation/direction representation.

## Selection

Write `S(r,b) = (b',R,P)` for the selector of relation `r` from binding `b`.
`R` is the list of new row variables; `P` is their correlation/guard predicates.

```
S(identity, b) = (b, [], [])

S(t ; r, b) = (b2, R1 ++ R2, P1 ++ P2)
  where (b1, R1, P1) = S(t, b)
        (b2, R2, P2) = S(r, b1)
```

These are `selectRelation`'s two recursive cases. Composed relations produce one
selector, not nested arrays. Distinct relation occurrences are not silently
merged: two map keys leading to the same person remain two witnesses.

`selectStep` supplies the primitive interpretation:

```
inline field       = same row variable, another semantic point
owned child table  = fresh child variable + child.ownerKey = current.ownerKey
owned parent       = existing owner binding from the ownership chain
identity reference = fresh target variable + source.reference = target.storageKey
inverse reference  = fresh source/owner bindings + source.reference = current.storageKey
```

A self-reference is NOT inline just because both endpoints use the same table.
It always introduces a fresh variable. Returning to an owner discards descendant
bindings from its scope: following its collection again must enumerate members,
not reuse the member from which we arrived.

The storage compiler emits `pgValueOrigin`, `pgBindings`,
`pgPresenceBindings`, and `pgOwnerReference` in each `PgTable`. This retains the
semantic provenance of the representation decisions. The read compiler does
not construct column or table names from strings and does not guess an owner
FK from its target table alone.

## Guards

```
Present(a)       = stored presence marker for a is true
TagEquals(a, t)  = stored tag at a equals t
```

An edge's guards are evaluated in the binding belonging to that edge. Inverse
reference traversal therefore tests the newly selected source's guards, not the
current target's guards. Optional empty records have explicit `OptionalValue`
rules, so absence remains distinguishable from an existing `{}`.

## JSON packaging

For `S(r,b) = (b',R,P)` and recursively computed payload `J(b',projection)`:

```
R = []:       CASE WHEN P THEN payload ELSE JSON null
R nonempty:  q = SELECT payload FROM R WHERE P

ExactlyOne -> scalar subquery(q)
AtMostOne  -> scalar subquery(q)
Unbounded  -> ordered jsonb_agg(q), or [] when empty
```

No `LIMIT 1` is used. More than one row in a singular selector is a PostgreSQL
cardinality error. Zero matches become JSON null in the prepared statement or
SQL-function wrapper. A required reference's existence is enforced by the
storage FK; a missing center remains a normal lookup result.

Ordering is part of the aggregate itself. It uses the physical row keys for a
stable serialization in a fixed layout; it is not an ontological ordering of a
set and is not promised to survive a representation-changing migration.

```
J(record)           = object of the selected child expressions
J(scalar)           = column expression
J(scalar + context) = {value: scalar, ... selected inverse relations}
J(set)              = array of selected members
J(map)              = array of {key: selected arguments, value: selected payload}
J(alternative)      = selected tag + only the active selected branch
J(terminal Ref T)   = T's semantic key, never its SQL surrogate
```

An optional selected property is represented by JSON null when absent. An
unselected relation contributes no property at all. A structural node stopped
by the projector is represented as `{"$cutoff":"DepthLimit"}` (or
`RepeatedAddress`), rather than falsely reporting an empty collection. Atomic
values at a cutoff remain readable without traversing another semantic edge;
a reference's own value is its semantic key.

Forward fields use their field names. Inverse edges currently use `^` labels;
inverse reference labels include the full source address to avoid collisions
between different references to the same population. Human-facing labels are
not part of this compiler pass.

## Parameterized functions

```
signature(center) = expandReferenceKeys(siteKey(center))
compilePrepared(view, storage) = SQL query AST
invoke(signature, named values) = validated, ordered parameter values
```

Each `Parameter` retains its originating `KeyPart` and a semantic reference-key
route. Thus a map argument `year: Ref<Year>` whose target key is `startYear`
produces a numeric parameter and an `EXISTS` over the target's semantic key,
not a bigint parameter. Nested records flatten; reference-key cycles fail with
a diagnostic because their expansion is not a finite tuple.

`compilePrepared` receives no instance values. `compileRead` is a convenience
adapter for existing callers and uses the same definition. SQL rendering is the
only production layer that concatenates SQL syntax.

The generated SQL functions are `STABLE SECURITY INVOKER`. Function deployment,
HTTP routes, authorization policy, and grants are separate concerns.

## Executable checks

`test/TraversalMain.hs` builds an ontology and prepared views, then emits SQL
fixtures, generated SQL functions, PostgreSQL PREPARE/EXECUTE calls, and paired
expected/actual results. `test/check-read-results.py` compares the JSON values.
CI fails on omitted results, additional rows, malformed JSON, wrong shapes, or
wrong payloads, not just on SQL syntax errors. Existing ontology, centering and
projection tests remain enabled.

