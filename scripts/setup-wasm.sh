#!/usr/bin/env bash
set -euo pipefail
# The upstream installer provides the complete matching SDK, libffi, GHC and
# Cabal toolchain. Pin its source; normal native development remains unchanged.
command -v node >/dev/null
revision=8079eb96bbc63823d99ad8acaff0765532625474
archive=$(mktemp)
checkout=$(mktemp -d)
trap 'rm -f "$archive"; rm -rf "$checkout"' EXIT
curl -fL --retry 3 "https://codeload.github.com/haskell-wasm/ghc-wasm-meta/tar.gz/$revision" -o "$archive"
python3 - "$archive" <<'PYHASH'
from pathlib import Path
import hashlib
import sys
expected = '4a1d62b2bea9f7c811cfad3d6e0e3ff6d000dfc53b2ea43dfcb3ae7c51345220'
if hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest() != expected:
    raise SystemExit('Wrong WASM toolchain source archive checksum')
PYHASH
tar xzf "$archive" -C "$checkout" --strip-components=1
# Upstream setup.sh replaces PREFIX: use a dedicated toolchain directory.
PREFIX="${WASM_TOOLCHAIN_DIR:-$HOME/.ghc-wasm-ontology}" FLAVOUR=9.12 bash "$checkout/setup.sh"
# The upstream bundled Node is static and cannot load Vite/Rollup native addons.
# Capture the active host Node when env is sourced, including after CI cache restore.
python3 - "${WASM_TOOLCHAIN_DIR:-$HOME/.ghc-wasm-ontology}/env" <<'PYENV'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text('ontology_frontend_node=$(command -v node)\n' + path.read_text()
    + '\nexport PATH="$(dirname "$ontology_frontend_node"):$PATH"\nunset ontology_frontend_node\n')
PYENV
