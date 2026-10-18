#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-unit}"
case "$mode" in unit|postgres) ;; *) echo 'Usage: scripts/check.sh {unit|postgres}' >&2; exit 2 ;; esac
if [[ "$mode" == postgres && "${ONTOLOGY_TEST_DATABASE:-}" != 1 ]]; then
  echo 'Use a disposable database and set ONTOLOGY_TEST_DATABASE=1.' >&2
  exit 2
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
compile() {
  local name="$1" source="$2"
  mkdir -p "$work/$name"
  "${GHC:-ghc}" -O0 -Wall -Werror -isrc -package megaparsec -package scientific -package mtl -package containers -package time -outputdir "$work/$name" "$source" -o "$work/$name/run"
}
compile model-test test/Main.hs
"$work/model-test/run"
compile parser-test test/OSQLMain.hs
"$work/parser-test/run" docs/o-sql/examples
compile compiler-test test/OSQLCompileMain.hs
"$work/compiler-test/run" docs/o-sql/examples > "$work/osql.sql"
compile backend-test test/SQLMain.hs
"$work/backend-test/run" > "$work/backend.sql"
build/ontology --version
build/ontology check examples/school.ontology --root School
build/ontology inspect examples/school.ontology --root School > "$work/inspect.txt"
build/ontology compile examples/school.ontology --root School > "$work/schema.sql"
build/ontology query examples/school.ontology examples/school.osql --root School > "$work/query.sql"
python3 test/cli.py
if [[ "$mode" == postgres ]]; then
  psql -X -qAt -v ON_ERROR_STOP=1 -f "$work/backend.sql" > "$work/backend.jsonl"
  psql -X -qAt -v ON_ERROR_STOP=1 -f "$work/osql.sql" > "$work/osql.jsonl"
  python3 test/check-read-results.py "$work/backend.jsonl"
  python3 test/check-read-results.py "$work/osql.jsonl"
  psql -X -qAt -v ON_ERROR_STOP=1 -f "$work/schema.sql"
  psql -X -qAt -v ON_ERROR_STOP=1 -f examples/school-data.sql
  psql -X -qAt -v ON_ERROR_STOP=1 -f "$work/query.sql" > "$work/school.jsonl"
  python3 - "$work/school.jsonl" <<'PYTHON'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert rows == [[{'course':'MATH','teacher':'Alice','students':['Bob']}]], rows
print('Verified the quickstart against PostgreSQL.')
PYTHON
fi
echo 'Ontology checks passed.'

