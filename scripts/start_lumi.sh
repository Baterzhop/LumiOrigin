#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.venv"
PORT="${LUMI_PORT:-8790}"
HOST="${LUMI_HOST:-127.0.0.1}"

if [[ ! -x "$VENV/bin/lumi-core" ]]; then
  echo "Lumi Core is not installed. Run scripts/install_lumi.sh first." >&2
  exit 1
fi

source "$VENV/bin/activate"
cd "$ROOT"

cleanup() {
  if [[ -n "${CORE_PID:-}" ]]; then
    kill "$CORE_PID" >/dev/null 2>&1 || true
    wait "$CORE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

lumi-core serve --host "$HOST" --port "$PORT" &
CORE_PID=$!

python - <<PY
import time
import httpx
url = "http://$HOST:$PORT/ready"
deadline = time.time() + 20
while time.time() < deadline:
    try:
        r = httpx.get(url, timeout=1)
        if r.status_code == 200 and r.json().get("ok") is True:
            raise SystemExit(0)
    except Exception:
        pass
    time.sleep(0.25)
raise SystemExit("Lumi Core did not become ready within 20 seconds")
PY

if [[ "$(uname -s)" == "Darwin" && -d "$ROOT/dist/Lumi.app" ]]; then
  open "$ROOT/dist/Lumi.app"
  echo "Lumi is running. Keep this terminal open; Ctrl-C stops Lumi Core."
  wait "$CORE_PID"
else
  echo "Lumi Core is ready at http://$HOST:$PORT"
  wait "$CORE_PID"
fi
