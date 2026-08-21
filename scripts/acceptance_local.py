#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from urllib.error import URLError
from urllib.request import Request, urlopen


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def request_json(url: str, *, method: str = "GET", payload: dict | None = None, timeout: float = 2.0) -> dict:
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = Request(url, data=data, headers=headers, method=method)
    with urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def wait_ready(url: str, process: subprocess.Popen, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    last_error = "not_started"
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"process_exited:{process.returncode}")
        try:
            payload = request_json(url, timeout=1.0)
            if payload.get("ok") is True:
                return
            last_error = str(payload)
        except Exception as exc:
            last_error = type(exc).__name__
        time.sleep(0.2)
    raise TimeoutError(f"service_not_ready:{last_error}")


def terminate(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a deterministic local Lumi Core acceptance test.")
    parser.add_argument("--keep-data", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    mock_port = free_port()
    core_port = free_port()
    temp_context = tempfile.TemporaryDirectory(prefix="lumi-acceptance-")
    data_dir = Path(temp_context.name)
    mock: subprocess.Popen | None = None
    core: subprocess.Popen | None = None

    env = dict(os.environ)
    env.update(
        {
            "PYTHONDONTWRITEBYTECODE": "1",
            "LUMI_DATA_DIR": str(data_dir),
            "LUMI_DATABASE_PATH": str(data_dir / "lumi.sqlite3"),
            "LUMI_BACKUP_DIR": str(data_dir / "backups"),
            "LUMI_TOOL_WORKSPACE": str(data_dir / "workspace"),
            "LUMI_OLLAMA_URL": f"http://127.0.0.1:{mock_port}/api/chat",
            "LUMI_OLLAMA_EMBED_URL": f"http://127.0.0.1:{mock_port}/api/embed",
            "LUMI_OLLAMA_MODEL": "lumi-mock",
            "LUMI_EMBEDDING_MODEL": "lumi-mock-embed",
            "LUMI_RAG_DENSE": "false",
            "LUMI_BACKUP_BEFORE_MIGRATE": "false",
            "LUMI_API_DOCS": "false",
        }
    )

    try:
        mock = subprocess.Popen(
            [sys.executable, str(root / "scripts/mock_ollama.py"), "--port", str(mock_port)],
            cwd=root,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
        )
        wait_ready(f"http://127.0.0.1:{mock_port}/api/tags", mock)

        core = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "lumi_core.api.main:app",
                "--host",
                "127.0.0.1",
                "--port",
                str(core_port),
                "--no-access-log",
            ],
            cwd=root,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
        )
        wait_ready(f"http://127.0.0.1:{core_port}/ready", core)

        health = request_json(f"http://127.0.0.1:{core_port}/health")
        if health.get("service") != "lumi-core":
            raise AssertionError(f"unexpected_health:{health}")

        response = request_json(
            f"http://127.0.0.1:{core_port}/v1/chat",
            method="POST",
            payload={"message": "Run deterministic acceptance"},
            timeout=10.0,
        )
        if response.get("fallback") is not False or response.get("provider") != "ollama":
            raise AssertionError(f"model_fallback_detected:{response}")
        if response.get("content") != "Lumi local acceptance OK":
            raise AssertionError(f"unexpected_model_content:{response}")

        print(json.dumps({"ok": True, "health": health, "chat": {"provider": response.get("provider"), "model": response.get("model")}}, indent=2))
        return 0
    finally:
        terminate(core)
        terminate(mock)
        if args.keep_data:
            temp_context.cleanup = lambda: None  # type: ignore[method-assign]
            print(f"acceptance_data={data_dir}")
        else:
            temp_context.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
