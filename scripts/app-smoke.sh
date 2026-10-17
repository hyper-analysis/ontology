#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
build/ontology-app test/fixtures/labels.ontology Root test/fixtures/labels.en.label examples/labels.app.json "$work/app"
test -s "$work/app/sql/schema.sql"
test -s "$work/app/package.json"
test -s "$work/app/views.txt"
if build/ontology-app test/fixtures/labels.ontology Root test/fixtures/labels.en.label examples/labels.app.json "$work/app" >/dev/null 2>&1; then
  echo 'Compiler overwrote an existing output directory' >&2
  exit 1
fi
echo 'Application generation and overwrite refusal passed.'

