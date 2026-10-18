"""Check the public compiler's explicit source and package boundary."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
expected=["src/OSQL/Check.hs","src/OSQL/Checked.hs","src/OSQL/Compile.hs","src/OSQL/Parser.hs","src/OSQL/Storage.hs","src/OSQL/Syntax.hs","src/OSQL/Target.hs","src/OSQL/Timestamp.hs","src/OSQL/Type.hs","src/Ontology/Check.hs","src/Ontology/Parser.hs","src/Ontology/Postgres.hs","src/Ontology/Relational.hs","src/Ontology/Syntax.hs","src/Postgres/Mapping.hs","src/Postgres/Physical.hs","src/SQL/Query.hs","src/SQL/Reference.hs","src/SQL/Render.hs","src/SQL/Syntax.hs","src/SQL/Validate.hs","src/Workbench/Compile.hs"]
actual={p.relative_to(root).as_posix() for p in root.glob("src/**/*.hs")}
assert actual == set(expected), "Unexpected compiler source files"
runtime=(root/"browser-runtime/browser-runtime.cabal").read_text()
assert "build-depends: ontology-language" in runtime
assert (root/"osql-workbench/dist/runtime/workbench.wasm").stat().st_size>1000
print("Public compiler source boundary and WASM distribution checks passed.")
