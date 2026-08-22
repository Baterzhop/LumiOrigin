#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Run Lumi's physical target-Mac automatable GA gate against the installed managed Core.

Prerequisite: finish the first-run Lumi model setup and select the actual Ollama model first.

Usage:
  scripts/ga_target_mac.sh [--output PATH] [--base-url URL] [--no-write-probe]

The default run explicitly approves one temporary exact-argument workspace.write_text probe.
The marker is deleted immediately after verification. This script does NOT claim Apple
notarization, real-user-document citation, or repository governance completion.
EOF
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This gate must run on the physical target Mac." >&2
  exit 2
fi

APP="${LUMI_APP_PATH:-$HOME/Applications/Lumi.app}"
RUNTIME="${LUMI_RUNTIME_DIR:-$HOME/Library/Application Support/Lumi/runtime/venv}"
CORE="${LUMI_CORE_BIN:-$RUNTIME/bin/lumi-core}"
PYTHON="${LUMI_CORE_PYTHON:-$RUNTIME/bin/python}"
BASE_URL="${LUMI_CORE_URL:-http://127.0.0.1:8790}"
OUTPUT="${LUMI_GA_EVIDENCE:-$HOME/Desktop/Lumi-GA-machine-evidence.json}"
WRITE_PROBE=1

while (($#)); do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a path" >&2; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    --base-url)
      [[ $# -ge 2 ]] || { echo "--base-url requires a URL" >&2; exit 2; }
      BASE_URL="$2"
      shift 2
      ;;
    --no-write-probe)
      WRITE_PROBE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d "$APP" ]] || { echo "Lumi.app not found at: $APP" >&2; exit 2; }
[[ -x "$CORE" ]] || { echo "Installed lumi-core not found at: $CORE" >&2; exit 2; }
[[ -x "$PYTHON" ]] || { echo "Installed Core Python not found at: $PYTHON" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/ga_machine_check.py"
[[ -f "$CHECKER" ]] || { echo "GA checker missing: $CHECKER" >&2; exit 2; }

wait_for_ready() {
  "$PYTHON" - "$BASE_URL" <<'PY'
import os, sys, time
import httpx
base = sys.argv[1].rstrip("/")
key = os.getenv("LUMI_API_KEY", "").strip()
headers = {"X-Lumi-Key": key} if key else {}
deadline = time.time() + 45
while time.time() < deadline:
    try:
        response = httpx.get(base + "/ready", headers=headers, timeout=1.5)
        if response.status_code == 200 and response.json().get("ok") is True:
            raise SystemExit(0)
    except Exception:
        pass
    time.sleep(0.35)
raise SystemExit("Lumi Core did not become ready within 45 seconds")
PY
}

echo "Opening installed Lumi app: $APP"
open "$APP"
wait_for_ready

ARGS=("$CHECKER" --base-url "$BASE_URL" --require-model --output "$OUTPUT")
if [[ "$WRITE_PROBE" -eq 1 ]]; then
  ARGS+=(--approve-tool-write)
fi

"$PYTHON" "${ARGS[@]}"

echo
echo "Automatable target-Mac evidence written to: $OUTPUT"
echo "Remaining external/manual evidence is intentionally listed inside that JSON."
echo "Do not rename the release to 4.0.0 GA until those remaining checks are actually completed."
