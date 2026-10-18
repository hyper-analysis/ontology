# Browser compiler

The workbench runs the same Haskell ontology and O-SQL compiler as the CLI.
`Workbench.Runtime` provides a small JSON transport with `compile` and `query`
operations. `app/Main.hs` is the native reference transport; `app/Browser.hs`
exports that transport from a GHC WebAssembly reactor.

The frontend runs compilation, data generation and PGlite in a Web Worker.
There is no Express server or remote PostgreSQL dependency. Generated query
results retain PostgreSQL's JSON text, including exact decimals.

## Build

Install Node.js 22+, Python, curl, jq, unzip and zstd, then:

```sh
bash scripts/setup-wasm.sh
source "$HOME/.ghc-wasm-ontology/env"
npm --prefix osql-workbench ci
npm --prefix osql-workbench run build:browser
```

The first build downloads the pinned GHC WASM toolchain and Haskell packages.
The final static directory is `osql-workbench/dist`; it works under a URL
subdirectory. Serve it over HTTP(S), not `file://`.

Models and selectors are saved in the browser's local storage. Generated data
is held in memory and is lost on reload. The worker resets after a timed-out
operation; compile and generate again to restore the workspace.

## Validate

The Pages workflow compares native and WASM responses on valid models, invalid
programs, Unicode and exact numeric queries, then runs the complete workflow in
Chromium with application API requests blocked. Only a static file server is
used. The tested directory is packaged beneath `workbench/` on the project site.

The public build contains only the modeling and query compiler and its three
workbench pages. Application generation is independent of this runtime.
