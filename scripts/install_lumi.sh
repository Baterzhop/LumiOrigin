#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
BUILD_APP=1
INSTALL_USER_APP=1

for arg in "$@"; do
  case "$arg" in
    --core-only)
      BUILD_APP=0
      INSTALL_USER_APP=0
      ;;
    --no-user-app)
      INSTALL_USER_APP=0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

"$PYTHON" - <<'PY'
import sys
if sys.version_info < (3, 11):
    raise SystemExit("Lumi requires Python 3.11 or newer.")
print("Python", sys.version.split()[0])
PY

cd "$ROOT"

if [[ "$(uname -s)" == "Darwin" ]]; then
  RUNTIME_ROOT="${LUMI_RUNTIME_ROOT:-$HOME/Library/Application Support/Lumi/runtime}"
  VENV="${LUMI_VENV:-$RUNTIME_ROOT/venv}"
  DATA_DIR="${LUMI_DATA_DIR:-$HOME/Library/Application Support/Lumi/data}"
else
  VENV="${LUMI_VENV:-$ROOT/.venv}"
  DATA_DIR="${LUMI_DATA_DIR:-$ROOT/.lumi-data}"
fi

mkdir -p "$(dirname "$VENV")" "$DATA_DIR"
"$PYTHON" -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install -c services/core/requirements.lock "services/core[dev]"
"$VENV/bin/python" -m pip check
LUMI_DATA_DIR="$DATA_DIR" LUMI_RAG_DENSE=false "$VENV/bin/lumi-core" doctor --initialize --no-model --require-database

if [[ "$(uname -s)" == "Darwin" && "$BUILD_APP" -eq 1 ]]; then
  bash scripts/build_macos_app.sh
  if [[ "$INSTALL_USER_APP" -eq 1 ]]; then
    USER_APPS="$HOME/Applications"
    mkdir -p "$USER_APPS"
    rm -rf "$USER_APPS/Lumi.app"
    ditto "$ROOT/dist/Lumi.app" "$USER_APPS/Lumi.app"
  fi
fi

cat <<EOF
Lumi V4 installation is ready.

Runtime:
  $VENV

Data:
  $DATA_DIR

Diagnostics:
  LUMI_DATA_DIR="$DATA_DIR" "$VENV/bin/lumi-core" doctor
EOF

if [[ "$(uname -s)" == "Darwin" && "$BUILD_APP" -eq 1 ]]; then
  if [[ "$INSTALL_USER_APP" -eq 1 ]]; then
    cat <<EOF

Launch Lumi:
  open "$HOME/Applications/Lumi.app"

The native app will start and stop the local Core automatically when needed.
EOF
  else
    cat <<EOF

Launch Lumi:
  open "$ROOT/dist/Lumi.app"
EOF
  fi
else
  cat <<EOF

Start Core:
  "$VENV/bin/lumi-core" serve
EOF
fi
