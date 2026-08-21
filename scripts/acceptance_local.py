#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys

from lumi_core.acceptance import run_acceptance


def main() -> int:
    parser = argparse.ArgumentParser(description="Lumi V4 local acceptance test")
    parser.add_argument("--base-url", default=os.getenv("LUMI_CORE_URL", "http://127.0.0.1:8790"))
    parser.add_argument("--require-model", action="store_true")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")
    try:
        result = run_acceptance(
            args.base_url,
            require_model=args.require_model,
            api_key=os.getenv("LUMI_API_KEY", "").strip() or None,
            timeout_seconds=args.timeout,
        )
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
