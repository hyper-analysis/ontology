#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
wasm32-wasi-cabal build browser-runtime:workbench-wasm --project-file=cabal.project.wasm --builddir=dist-wasm
binary=$(wasm32-wasi-cabal list-bin browser-runtime:workbench-wasm --project-file=cabal.project.wasm --builddir=dist-wasm)
mkdir -p osql-workbench/public/runtime
cp "$binary" osql-workbench/public/runtime/workbench.wasm
node "$(wasm32-wasi-ghc --print-libdir)/post-link.mjs" -i osql-workbench/public/runtime/workbench.wasm -o osql-workbench/public/runtime/workbench.js
