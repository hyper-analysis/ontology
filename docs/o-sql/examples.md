# Hand-checked O-SQL examples

[Specification](README.md) · [BNF](grammar.bnf) · [Typing](typing.md) · [Evaluation](semantics.md)

Each query file is a complete program under the ontology named below, without
undeclared external parameters. `noon`, where used, is a top-level timestamp
binding. These are authored syntax/type examples and hand calculations, not
executed O-SQL acceptance results. Optional(T) abbreviates T ∨ Null.

## 1. Example inventory

The [basic fixture](examples/fixture.ontology) declares Person, Lesson, Schooling,
a Resident/Visitor Role alternative and composite-key Site.

| File | Hand-derived result type under the basic fixture |
| --- | --- |
| [keyed-city.osql](examples/keyed-city.osql) | Text; field access may raise MissingValue |
| [optional-alice.osql](examples/optional-alice.osql) | Optional(Person); a missing key succeeds with null |
| [nullable-navigation.osql](examples/nullable-navigation.osql) | {city:Optional(Text); teacher:Optional(Text); absent:Boolean} |
| [nested-lessons.osql](examples/nested-lessons.osql) | Set<{person:Person; lessons:Set<Lesson>}> |
| [teacher-cities.osql](examples/teacher-cities.osql) | Set<Text> |
| [grouped-cities.osql](examples/grouped-cities.osql) | Set<{city:Text; residents:Set<Person>; count:Number}> |
| [composite-key.osql](examples/composite-key.osql) | Optional(Site) |
| [map-entries.osql](examples/map-entries.osql) | Set<{year:Number; track:Text; label:Text}>; Alice field access may fail |
| [branch-cities.osql](examples/branch-cities.osql) | Set<Text>; now uses match rather than a branch builtin |
| [match-values.osql](examples/match-values.osql) | Set<{value:Text ∨ {destination:Text}}> |
| [quantified.osql](examples/quantified.osql) | Set<Person> |
| [single-person.osql](examples/single-person.osql) | Person, or CardinalityFailure |
| [unique-city.osql](examples/unique-city.osql) | Boolean, testing exactly one distinct projected city |
| [query-bindings.osql](examples/query-bindings.osql) | {city:Text; uniqueCity:Boolean; uniquePerson:Boolean}, or binding CardinalityFailure |

The separate [roles ontology](examples/roles.ontology) declares Student/Teacher
roles and Online/OnSite lesson delivery. The complete
[complex-roles.osql](examples/complex-roles.osql) uses that ontology, not the basic
fixture. Its heterogeneous result type and hand trace are in section 6.

Person, Lesson and Site abbreviate their Entity types. Projected records have no
newly created entity identity. Read displayed primitive types as safe widened
summaries of literal refinements retained by the checker.

## 2. Alice: lookup, strict access and optional access

The basic ontology supplies:

```text
root.people : Set(Entity(Person))
keyΣ(Person) = (name: Text)
fieldΣ(Entity(Person), city) = Text
```

The key argument and lookup derive as follows:

$$
\Sigma;\varnothing\vdash\text{"alice"}:\operatorname{Literal}(\text{"alice"})
\qquad\operatorname{Literal}(\text{"alice"})\preceq\mathrm{Text}
$$

$$
\Sigma;\varnothing\vdash\mathrm{root.people}(\text{"alice"}):
\operatorname{Entity}(\mathrm{Person})\lor\mathrm{Null}
$$

After `let alice = root.people("alice");`, Γ(alice) = Person ∨ Null.
Binding alice succeeds even when the lookup returns null. Ordinary field access
demands its non-null receiver type:

$$
\operatorname{nn}(\Gamma(\mathrm{alice}))=\operatorname{Entity}(\mathrm{Person})
\qquad
\Sigma;\Gamma\vdash\mathrm{alice.city}:\mathrm{Text}
$$

It can therefore be well-typed and raise MissingValue at execution. Optional
access produces a nullable result instead:

$$
\Sigma;\Gamma\vdash\mathrm{alice?.city}:\mathrm{Text}\lor\mathrm{Null}
$$

In nullable-navigation, alice?.teacher?.name protects both optional receivers.
If Alice exists but teacher is absent, alice.teacher itself succeeds with null;
only a subsequent ordinary access on that null would throw. The named lookup
`root.people(name: "alice")` has the same nullable type as the positional form.

## 3. Ordered scopes and chains

For teacher-cities, the local environments develop as follows:

```text
Δ₀ = {}
from root.people as person        Δ₁ = {person: Person}
let teacher = person.teacher     Δ₂ = Δ₁ + {teacher: Person ∨ Null}
where not (teacher = null)        Δ₃ = Δ₂
let teacherCity = teacher.city    Δ₄ = Δ₃ + {teacherCity: Text}
```

The projection, although written first, is checked in Δ₄. The filter removes
null runtime receivers without refining Γ; ordinary field access carries the
possible failure and succeeds for every binding that actually reaches it.

With this illustrative population:

| Person key | City | Teacher |
| --- | --- | --- |
| alice | Paris | null |
| bob | Lyon | alice |
| claire | Nice | alice |

the result is Set{"Paris"}. Alice's binding is filtered; Bob and Claire project
the same city. Moving the strict field access before the filter raises
MissingValue on Alice. Moving the harmless teacher lookup itself does not.
These are hand calculations, not an executed O-SQL trace.

The following chain distinctions use fields declared by the basic fixture:

| Expression | Absent first teacher | Present first teacher, absent second teacher |
| --- | --- | --- |
| `person.teacher?.teacher.name` | null: suffix skipped | MissingValue at name |
| `person.teacher?.teacher?.name` | null | null |

A suffix after parentheses is now banned: `(person.teacher?.teacher).name` is a
syntax error regardless of data. The supported chains have literal field labels;
there is no computed-attribute form.

Optional chaining does not catch errors raised while computing its receiver,
and it never permits an unknown field name.

## 4. Nested queries, keys and map entries

In nested-lessons, the inner query can see the outer person and top-level noon.
Its lesson binding remains local. earlyLessons is Set<Lesson>, so count returns
Number. grouped-cities computes distinct cities and a correlated Set<Person>
for each city; no separate `group by` clause is claimed.

In quantified, query-existence and bounded every bind lesson in different local
scopes and use the enclosing person/noon. Neither leaks its name outward.

Site declares country and code as immediate key components. Argument order is
irrelevant; both are mandatory. Schooling entries have type:

```text
Set<{
    key: {year: Number; track: Text};
    value: {label: Text}
}>
```

Distinct years/tracks preserve distinct entry records even when their labels
coincide. Map lookup returns a nullable label record instead. In map-entries,
a missing Alice does not fail the top-level binding; accessing alice.schooling
fails when the source is evaluated.

## 5. Match extraction and heterogeneous values

branch-cities uses an exhaustive match returning either a Resident payload or
null. Its local resident type is Record{city:Text} ∨ Null. A null filter prevents
ordinary resident.city from executing on Visitor bindings. There is no branch
builtin and no mandatory explicit unwrap operation.

match-values instead returns different shapes directly:

```text
match person.role {
    Resident resident => resident.city;
    Visitor visitor => { destination: visitor.destination };
}
```

The result type is Text ∨ Record{destination:Text}. Neither arm is converted to
the other's shape. For a Resident in Paris the result is the text "Paris"; for
a Visitor to Rome it is the record {destination:"Rome"}. No output role tag is
inserted automatically. Only the selected arm runs, but both arms are checked.

A useful fallback example under the same fixture is:

```text
select match person.role {
    Resident resident => resident.city;
    _ => null;
} as city
from root.people as person
```

Its type is Set<{city:Optional(Text)}>. `_` covers Visitor and binds no payload.
It does not handle a null scrutinee or suppress an evaluation error.

## 6. Complex roles: nested alternatives, maps and quantifiers

[complex-roles.osql](examples/complex-roles.osql) uses the complete
[roles ontology](examples/roles.ontology). The outer match inspects each person's
role. Student details include an optional adviser name and upcoming enrollments;
Teacher details include the supervised students who attend every taught lesson.
There is no branch extraction followed by a second presence test.

Inside the Student arm, each enrollment supplies a lesson reference. Its delivery
match returns either online platform/url or on-site campus/room. Another delivery
match is the Boolean filter selecting Teams or Paris. Neither accesses fields
from the other branch. Inside the Teacher arm, the candidate-role match binds a
Student payload only where the enrollment quantifier needs it; Teacher candidates
return false without evaluating Student-specific operations.

The hand-derived types are:

```text
Attendance = {platform:Text; url:Text}
           ∨ {campus:Text; room:Text}

StudentDetails = {
    programme:Text;
    adviser:Optional(Text);
    upcomingLessons:Set<{year:Number; lesson:Lesson; attendance:Attendance}>
}

TeacherDetails = {
    department:Text;
    supervisedStudents:Set<Person>
}

Result = Set<{person:Person; details:StudentDetails ∨ TeacherDetails}>
```

These abbreviations describe inferred query types, not additional ontology
declarations. Neither result union requires a common record-field set.

For a hand run, take these complete values under roles.ontology; lesson names
in maps/sets designate references to the keyed Lesson objects below:

| Person | Active role and payload |
| --- | --- |
| alice | Student {programme:"Maths"; adviser:bob; enrollments:(2026,"L1")↦{lesson:L1}, (2026,"L2")↦{lesson:L2}, (2026,"L3")↦{lesson:L3}} |
| bob | Teacher {department:"Mathematics"; lessons:{L1,L2}} |
| claire | Student {programme:"Physics"; adviser:null; enrollments:empty map} |

| Lesson | startsAt | Active delivery and payload |
| --- | --- | --- |
| L1 | 2026-10-17T13:00:00Z | Online {platform:"Teams"; url:"https://meet.example/L1"} |
| L2 | 2026-10-17T14:00:00Z | OnSite {campus:"Paris"; room:"A12"} |
| L3 | 2026-10-17T15:00:00Z | Online {platform:"Zoom"; url:"https://meet.example/L3"} |

Hand trace:

1. Alice selects the Student arm. adviser?.name yields "bob". Her three map
   entries pass the date condition; L1 passes the Online/Teams arm and L2 the
   OnSite/Paris arm. L3 fails its Online filter. Attendance for L1 has platform/url;
   attendance for L2 has campus/room. No Teacher fields are evaluated.
2. Bob selects the Teacher arm. Alice's adviser equals Bob; both L1 and L2 have
   enrollment witnesses, so Alice is retained. Bob's candidate role returns
   false directly. Claire's absent adviser compares unequal to Bob; Boolean
   short-circuiting skips her enrollment quantifier. supervisedStudents is {alice}.
3. Claire selects the Student arm. adviser?.name returns null. Her empty map
   yields an empty upcomingLessons set, without an error.
4. The final set contains one record for each person, with the appropriate
   details shape. Returning whole persons does not eagerly expand reference
   cycles; entity designators retain semantic identity.

The universal checks taught lessons only: an empty taught-lesson set would make
every true. The independent adviser comparison would still be required. Missing
lookup results and inactive match arms are not reasons to throw; an executed
ordinary field access on null would be.

## 7. Singleness and query variables

single-person asserts that exactly one person named Alice is selected. No Alice
gives CardinalityFailure; it does not return null as a keyed lookup would. A
valid population cannot have two people with the same semantic key.

unique-city selects distinct Paris city values and tests their cardinality.
No qualifying people gives false; one or many people in Paris gives true,
because their identical projected text collapses into one value. Selecting the
people instead would test uniqueness of the matching person.

query-bindings stores a selected Set<Person> in people, then stores the unique
matching Person in alice. Later expressions use those runtime values, including
`exist!(people)` to test the bound set directly. Top-level
`let ... = select ...;` and `let ... = select! ...;` need no query wrapper; clause
bindings still parenthesize nested queries. There is no persistent view or limit.

## 8. Negative examples and failure phases

| Source | Expected diagnostic / outcome |
| --- | --- |
| `root.people()` | Syntax: application needs arguments |
| `a.(field)` or `a["city"]` | Syntax: computed field names are banned |
| `(a?.b).c` or `(select p from root.people as p)("alice")` | Syntax: grouped expressions cannot acquire postfix suffixes |
| `select p from root.people as p limit 1` | Syntax: limit is deferred |
| `select! p from root.people as p` | Runtime CardinalityFailure unless exactly one distinct projected person exists |
| `exist!(select p from root.people as p)` | Boolean false unless exactly one distinct person exists |
| `exist!(select! p from root.people as p)` | Checker rejects a Person-valued argument rather than Set |
| `exist!(people)` | Boolean uniqueness test of a previously bound Set |
| `root.people("alice", "bob")` | Syntax: multiple positional arguments unsupported |
| `root.people(name:"alice", name:"bob")` | Static: duplicate argument |
| `root.people(city:"Paris")` | Static: unknown/missing key argument |
| `root.sites(country:"FR")` | Static: missing code argument |
| `root.people(name:42)` | Static: incompatible key type |
| `root.people("alice").unknown` | Static: unknown Person field |
| `root.people("alice")?.unknown` | Static: optional chaining cannot invent a field |
| `root.people.city` | Static: Set subjects are not implicitly mapped |
| `select p.city, p.name from root.people as p` | Syntax: multiple projections must be named |
| `select p.city as x, p.name as x from root.people as p` | Static: duplicate output label |
| `select q from root.people as p` | Static: unbound q |
| `select p from root.people as p let p = p` | Static: duplicate local name |
| `select p from root.people as p where p.city` | Static: condition is not Boolean |
| `select x from root.people("alice") as x` | Static: nullable Person source is not Set |
| `first(root.people)` | Static: Set is not Sequence |
| `match root.people { _ => null; }` | Static: Set is not an alternative |
| `match root.people("alice").role { Resident r => r.city; }` | Static: missing Visitor arm |
| `match root.people("alice").role { Missing x => null; _ => null; }` | Static: unknown branch |
| `match root.people("alice").role { Resident r => r.city; Resident s => s.city; _ => null; }` | Static: duplicate arm |
| `match root.people("alice").role { _ => null; Resident r => r.city; }` | Syntax: fallback must be last |
| `match root.people("alice").role { Resident r => r.city; Visitor v => null; _ => null; }` | Static: unreachable fallback |
| `root.people("missing")` | Successful null if the key is absent |
| `root.people("missing").city` | Runtime MissingValue if the key is absent |
| `root.people("missing")?.city` | Successful null if the key is absent |
| `only(root.people)` | Runtime CardinalityFailure unless exactly one member exists |

For an explicitly supplied Sequence<Text> xs, `at(xs, 1.5)` is well-typed but
raises InvalidIndex. A free xs without that environment is a static name error.
Unknown `branch`, `present` or `require` names are not builtin calls; the general
application syntax may parse a name, but resolution still rejects it.

## 9. Parser checks and hand-evaluation limits

`OSQL.Parser` is now implemented. Its Haskell tests parse all fifteen complete
query files and test grammar rejection, AST precedence, cardinality modes,
ordered query bindings, match-arm payload scopes, literal/optional field chains,
exact decimals, JSON escapes and source diagnostics. The shared unit script
also builds and smoke-tests the osql-parse CLI. Both ontology fixtures validate
with the existing ontology parser/checker.

The result types and traces above remain hand-derived: no general O-SQL type
checker, evaluator or SQL conformance run is claimed. Parsing unknown fields,
duplicate names or incomplete branch coverage does not validate them; those are
preserved for the subsequent ontology-aware checker. Cardinality modes are
represented in the AST, not executed by the parser.

