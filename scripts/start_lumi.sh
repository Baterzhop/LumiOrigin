#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${LUMI_RUNTIME_DIR:-$ROOT/.lumi-runtime}"
VENV="$RUNTIME_DIR/venv"
HOST="${LUMI_BIND_HOST:-127.0.0.1}"
PORT="${LUMI_PORT:-8790}"

if [[ ! -x "$VENV/bin/uvicorn" ]]; then
  echo "Lumi runtime is not installed. Run scripts/install_lumi.sh first." >&2
  exit 2
fi

if [[ "$HOST" != "127.0.0.1" && "$HOST" != "::1" && "$HOST" != "localhost" && -z "${LUMI_API_KEY:-}" ]]; then
  echo "Refusing non-loopback bind without LUMI_API_KEY." >&2
  exit 2
fi

exec "$VENV/bin/uvicorn" lumi_core.api.main:app \
  --host "$HOST" \
  --port "$PORT" \
  --no-access-log
