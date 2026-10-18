# Ontology — application compilation experiment

**A semantic data modeling language that compiles to relational databases.**

Describe a domain in a `.ontology` file. The compiler derives PostgreSQL tables,
keys, references and integrity constraints. Query the same model with O-SQL,
using domain fields and semantic keys rather than generated table names.

```text
type Person = {
  key email: string;
  name: string;
};

type Course = {
  key code: string;
  teacher: Ref<Person>;
  students: Ref<Person>[];
};

type School = {
  people: Person[];
  courses: Course[];
};
```

```sh
ontology check examples/school.ontology --root School
ontology compile examples/school.ontology --root School > schema.sql
ontology inspect examples/school.ontology --root School
```

This produces independent Person and Course populations, a relation for course
students, foreign keys for references, and uniqueness for declared semantic keys.
See the [generated school schema](examples/school.sql).

For the experimental application compiler, see [setup and scope](docs/app-compilation.md).

## Browser workbench

The static workbench compiles the Haskell compiler to WebAssembly and runs generated SQL in PGlite. Model, generate data and query entirely in your browser. See [browser setup and behavior](docs/browser-workbench.md).

## Try it

The project is at **0.1.0**. Source builds are available now; downloadable
binaries are produced by the [release workflow](.github/workflows/release.yml)
when a version tag is pushed. There are no prebuilt releases promised yet.

With [Nix](https://nixos.org/):

```sh
git clone https://github.com/hyper-analysis/ontology.git
cd ontology
nix build
./result/bin/ontology compile examples/school.ontology --root School > schema.sql
```

Or build locally with GHC, Make and the dependencies listed in
[development](docs/development.md):

```sh
make
./build/ontology --help
make install                 # defaults to ~/.local/bin
```

The language has its own parser and semantics. Its familiar type syntax is not
TypeScript. The reference compiler is implemented in Haskell; ontology files
are data modeling source files, not Haskell programs.

## Query the ontology

```text
select c.code as course, c.teacher.name as teacher,
       (select s.name from c.students as s) as students
from root.courses as c
```

```sh
ontology query examples/school.ontology examples/school.osql --root School > query.sql
psql -v ON_ERROR_STOP=1 -f schema.sql
# Populate the database, then:
psql -X -qAt -v ON_ERROR_STOP=1 -f query.sql
```

`query` compiles O-SQL into PostgreSQL read functions and a JSONB result query;
it does not connect to a database or generate sample data. Install the schema
once, populate it, then execute compiled queries. Sets have no guaranteed
transport order. See [O-SQL](docs/o-sql/README.md) for semantics and backend limits.

## What it models

- Declared semantic identity with `key`, separate from storage IDs.
- Shared entities through `Ref<T>`; nested values through ownership.
- Sets, maps with named keys, optional fields and tagged alternatives.
- Object composition, scalar enumerations and uniqueness constraints.
- Compositional relational meaning before PostgreSQL-specific lowering.

See the [language reference](docs/language.md),
[compiler architecture](docs/architecture.md), [SQL backend](docs/sql-backend.md),
and the larger [tutoring example](examples/tutoring-company.ontology).

## Scope and direction

This release covers the modeling language, compiler and O-SQL.
Application compilation is a research direction: deriving typed server interfaces
and application structure from the same domain model. An experimental
[application compilation branch](https://github.com/hyper-analysis/ontology/tree/feat/app-compilation)
keeps that work separate from the released core. See the [roadmap](docs/roadmap.md).


The next compiler stages are explicit optimization rules and a Rust implementation
checked against the Haskell executable specification. These are planned directions;
the current compiler remains Haskell. See the [roadmap](docs/roadmap.md).

The syntax and generated storage layout may change before 1.0. Recompilation is
not a database migration strategy; inspect generated SQL before applying it.

## Contributing

Run `make test`; use `make sql-test` with a disposable PostgreSQL database for
execution checks. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and contribution scope.

Licensed under [Apache-2.0](LICENSE).

