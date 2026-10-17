# Development

The compiler uses GHC 9.4+ and these packages: containers, megaparsec, mtl,
scientific and time. Tests also use directory and filepath. CI uses Ubuntu
24.04's packaged GHC and libraries.

```sh
sudo apt-get install ghc make libghc-megaparsec-dev libghc-scientific-dev libghc-mtl-dev
make
make test
make install PREFIX="$HOME/.local"
```

Or use `nix develop`, then the same Make commands. `nix build` builds the CLI;
`nix run . -- --help` runs it. The lock file pins nixpkgs.
The Cabal package is also supported: `cabal build all` and `cabal test all`.
Normal language users only need the resulting `ontology` executable.

## Commands

| Command | Output |
| --- | --- |
| `ontology check FILE --root TYPE` | Validated ontology summary |
| `ontology compile FILE --root TYPE` | Complete PostgreSQL DDL |
| `ontology inspect FILE --root TYPE` | Relational interpretation |
| `ontology query FILE QUERY --root TYPE` | PostgreSQL functions and result query |
| `ontology --version` | Version |

`--root` is explicit; the compiler does not guess the root.
`query` also accepts `--namespace NAME` (default `osql_query`).
Diagnostics and result-type information go to stderr; generated SQL goes to stdout.
The CLI emits SQL and does not execute it.
The older `ontology-check`, `osql-parse` and `osql-compile` developer entry points
remain available through Cabal.

## Validation

`make test` compiles with `-Wall -Werror`, runs semantic, parser, checker and
backend tests, and compiles the published examples and CLI smoke examples.
For SQL execution, point standard PostgreSQL variables at a **disposable** database:

```sh
export PGHOST=localhost PGPORT=5432 PGUSER=postgres PGDATABASE=ontology_test
ONTOLOGY_TEST_DATABASE=1 make sql-test
```

The fixtures create schemas and objects. Use a fresh database on each run.
Tests compare actual PostgreSQL JSON results against expected values, retaining
numeric precision and treating arrays as unordered only when declared sets.
CI starts PostgreSQL 16 in an isolated service container.

## Releases

Push a `v*` tag after validation. The release workflow builds Linux x86_64 and
macOS ARM64 archives containing the CLI and license, plus SHA-256 checksums.
Linux builds use Ubuntu 24.04; these are native executables, not universal
static binaries. Other OS/architectures can build from source.

