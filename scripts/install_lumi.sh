#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${LUMI_RUNTIME_DIR:-$ROOT/.lumi-runtime}"
VENV="$RUNTIME_DIR/venv"
CONSTRAINTS="$ROOT/requirements/constraints-py312.txt"
PYTHON_BIN="${PYTHON_BIN:-python3}"

"$PYTHON_BIN" - <<'PY'
import sys
if sys.version_info < (3, 11):
    raise SystemExit("Lumi Core requires Python 3.11 or newer")
print(f"Using Python {sys.version.split()[0]}")
PY

mkdir -p "$RUNTIME_DIR"
"$PYTHON_BIN" -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip setuptools wheel
"$VENV/bin/python" -m pip install -c "$CONSTRAINTS" -e "$ROOT/services/core"
"$VENV/bin/lumi-core" doctor --initialize --skip-model

printf '\nLumi Core installed in %s\n' "$VENV"
printf 'Start with: %s/scripts/start_lumi.sh\n' "$ROOT"
