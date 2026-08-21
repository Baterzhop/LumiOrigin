#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
BUILD_APP=1

if [[ "${1:-}" == "--core-only" ]]; then
  BUILD_APP=0
fi

"$PYTHON" - <<'PY'
import sys
if sys.version_info < (3, 11):
    raise SystemExit("Lumi requires Python 3.11 or newer.")
print("Python", sys.version.split()[0])
PY

cd "$ROOT"
"$PYTHON" -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -c services/core/requirements.lock -e "services/core[dev]"
python -m pip check
LUMI_RAG_DENSE=false lumi-core doctor --initialize --no-model --require-database

if [[ "$(uname -s)" == "Darwin" && "$BUILD_APP" -eq 1 ]]; then
  bash scripts/build_macos_app.sh
fi

cat <<EOF
Lumi V4 local installation is ready.

Start Core:
  cd "$ROOT"
  source .venv/bin/activate
  lumi-core serve

Run diagnostics:
  source "$ROOT/.venv/bin/activate"
  lumi-core doctor

Run the macOS app:
  open "$ROOT/dist/Lumi.app"

Or use:
  "$ROOT/scripts/start_lumi.sh"
EOF
