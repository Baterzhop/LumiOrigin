#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" == "Darwin" ]]; then
  if [[ -d "$HOME/Applications/Lumi.app" ]]; then
    open "$HOME/Applications/Lumi.app"
    exit 0
  fi
  if [[ -d "$ROOT/dist/Lumi.app" ]]; then
    open "$ROOT/dist/Lumi.app"
    exit 0
  fi
  echo "Lumi.app is not installed. Run scripts/install_lumi.sh first." >&2
  exit 1
fi

VENV="${LUMI_VENV:-$ROOT/.venv}"
PORT="${LUMI_PORT:-8790}"
HOST="${LUMI_HOST:-127.0.0.1}"

if [[ ! -x "$VENV/bin/lumi-core" ]]; then
  echo "Lumi Core is not installed. Run scripts/install_lumi.sh first." >&2
  exit 1
fi

exec "$VENV/bin/lumi-core" serve --host "$HOST" --port "$PORT"
