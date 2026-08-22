#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlparse
import uuid

import httpx


def _run(args: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, env=env, check=check, text=True, capture_output=True)


def _json_command(args: list[str], *, env: dict[str, str] | None = None) -> dict:
    completed = _run(args, env=env)
    payload = json.loads(completed.stdout)
    if not isinstance(payload, dict):
        raise RuntimeError("command_did_not_return_json_object")
    return payload


def _api_key() -> str | None:
    explicit = os.getenv("LUMI_API_KEY", "").strip()
    if explicit:
        return explicit
    try:
        value = _run([
            "security", "find-generic-password", "-s", "app.lumi.desktop", "-a", "core-api-key", "-w"
        ]).stdout.strip()
    except Exception:
        return None
    return value or None


def _headers(api_key: str | None) -> dict[str, str]:
    return {"X-Lumi-Key": api_key} if api_key else {}


def _wait_ready(base_url: str, api_key: str | None, *, timeout: float = 45.0, expected: bool = True) -> bool:
    deadline = time.monotonic() + timeout
    with httpx.Client(base_url=base_url.rstrip("/"), headers=_headers(api_key), timeout=2.0) as client:
        while time.monotonic() < deadline:
            ok = False
            try:
                response = client.get("/ready")
                ok = response.status_code == 200 and response.json().get("ok") is True
            except Exception:
                ok = False
            if ok is expected:
                return True
            time.sleep(0.5)
    return False


def _port(base_url: str) -> int:
    parsed = urlparse(base_url)
    if parsed.port:
        return parsed.port
    return 443 if parsed.scheme == "https" else 80


def _listener_pids(port: int) -> set[int]:
    result = subprocess.run(
        ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
        text=True,
        capture_output=True,
        check=False,
    )
    pids: set[int] = set()
    for line in result.stdout.splitlines():
        try:
            pids.add(int(line.strip()))
        except ValueError:
            pass
    return pids


def _process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _open_app(app: Path) -> None:
    _run(["open", str(app)])


def _quit_app() -> None:
    subprocess.run(["osascript", "-e", 'tell application "Lumi" to quit'], check=False, text=True, capture_output=True)


def _app_version(app: Path) -> str:
    plist = app / "Contents" / "Info.plist"
    return _run(["plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", str(plist)]).stdout.strip()


def _candidate_commit(root: Path) -> str:
    return _run(["git", "-C", str(root), "rev-parse", "HEAD"]).stdout.strip()


async def _verify_tool_boundary(tmp: Path) -> tuple[bool, bool]:
    from lumi_core.agent.planner import PlannerDecision, ScriptedPlanner
    from lumi_core.agent.task_runtime import TaskRuntime
    from lumi_core.storage.database import Database
    from lumi_core.tools import PolicyEngine, Workspace, build_default_registry

    workspace_dir = tmp / "tool-workspace"
    workspace_dir.mkdir(parents=True, exist_ok=True)
    marker = f"read-marker-{uuid.uuid4().hex}"
    (workspace_dir / "input.txt").write_text(marker, encoding="utf-8")

    database = Database(tmp / "tool-boundary.sqlite3")
    database.migrate()
    registry = build_default_registry(Workspace(workspace_dir))
    write_value = f"approved-write-{uuid.uuid4().hex}"
    planner = ScriptedPlanner([
        PlannerDecision(action="tool", tool="workspace.read_text", arguments={"path": "input.txt", "max_chars": 500}),
        PlannerDecision(
            action="tool",
            tool="workspace.write_text",
            arguments={"path": "approved-output.txt", "content": write_value, "overwrite": False},
        ),
        PlannerDecision(action="finish", answer="done"),
    ])
    runtime = TaskRuntime(database, registry, PolicyEngine(), planner)
    snapshot = await runtime.create_and_run("verify exact approval boundary")
    calls = snapshot.get("tool_calls", [])
    read_ok = any(
        call.get("tool_name") == "workspace.read_text"
        and call.get("status") == "completed"
        and marker in json.dumps(call.get("result") or {})
        for call in calls
    )
    waiting = next((call for call in calls if call.get("tool_name") == "workspace.write_text"), None)
    output = workspace_dir / "approved-output.txt"
    if not waiting or waiting.get("status") != "awaiting_approval" or output.exists():
        return read_ok, False
    expected_arguments = dict(waiting.get("arguments") or {})
    final = await runtime.approve(str(waiting["id"]))
    completed = next(
        (call for call in final.get("tool_calls", []) if call.get("id") == waiting.get("id")),
        None,
    )
    write_ok = bool(
        completed
        and completed.get("status") == "completed"
        and completed.get("arguments") == expected_arguments
        and output.exists()
        and output.read_text(encoding="utf-8") == write_value
    )
    return read_ok, write_ok


def _restore_copy(core: Path, backup: Path, tmp: Path, api_key: str | None) -> bool:
    restore_data = tmp / "restore-data"
    restore_backups = tmp / "restore-backups"
    env = os.environ.copy()
    env["LUMI_DATA_DIR"] = str(restore_data)
    env["LUMI_BACKUP_DIR"] = str(restore_backups)
    env["LUMI_RAG_DENSE"] = "false"
    if api_key:
        env["LUMI_API_KEY"] = api_key
    doctor = _json_command([str(core), "doctor", "--initialize", "--no-model", "--require-database"], env=env)
    if doctor.get("ok") is not True:
        return False
    restored = _json_command([str(core), "restore", str(backup), "--yes", "--full"], env=env)
    if restored.get("ok") is not True:
        return False
    verify = _json_command([str(core), "doctor", "--no-model", "--require-database", "--full"], env=env)
    return verify.get("ok") is True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run Lumi V4 physical-Mac GA acceptance and emit machine-readable evidence.")
    parser.add_argument("--base-url", default=os.getenv("LUMI_CORE_URL", "http://127.0.0.1:8790"))
    parser.add_argument("--app", type=Path, default=Path.home() / "Applications" / "Lumi.app")
    parser.add_argument(
        "--core",
        type=Path,
        default=Path.home() / "Library" / "Application Support" / "Lumi" / "runtime" / "venv" / "bin" / "lumi-core",
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)

    if platform.system() != "Darwin":
        print("This acceptance must run on the physical target Mac.", file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parents[1]
    app = args.app.expanduser().resolve()
    core = args.core.expanduser().resolve()
    if not app.exists() or not core.exists():
        print("Install Lumi first with: bash scripts/install_lumi.sh", file=sys.stderr)
        return 2

    application_support = Path.home() / "Library" / "Application Support" / "Lumi"
    production_data_dir = application_support / "data"
    evidence_dir = application_support / "ga-evidence"
    output = args.output.expanduser() if args.output else evidence_dir / "4.0.0-ga.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    api_key = _api_key()
    env = os.environ.copy()
    env.setdefault("LUMI_DATA_DIR", str(production_data_dir))
    env.setdefault("LUMI_BACKUP_DIR", str(production_data_dir / "backups"))
    if api_key:
        env["LUMI_API_KEY"] = api_key

    result: dict[str, object] = {
        "schema_version": 1,
        "version": "4.0.0",
        "candidate_commit": _candidate_commit(root),
        "target_mac": {
            "ok": False,
            "timestamp_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "macos_version": platform.mac_ver()[0],
            "app_version": _app_version(app),
            "core_version": _run([str(core), "version"], env=env).stdout.strip(),
            "provider": "",
            "model": "",
            "real_model_ok": False,
            "fallback_false": False,
            "restart_ok": False,
            "durable_memory_ok": False,
            "grounded_citation_ok": False,
            "read_tool_ok": False,
            "approval_gated_write_ok": False,
            "backup_restore_copy_ok": False,
            "shutdown_ownership_ok": False,
        },
        "governance": {
            "main_protected": False,
            "pull_requests_required": False,
            "v4_ci_required": False,
            "force_push_blocked": False,
            "deletion_blocked": False,
        },
        "distribution": {
            "public": False,
            "notarization_ok": False,
            "codesign_ok": False,
            "notary_status": "NotRun",
            "stapler_ok": False,
            "gatekeeper_ok": False,
            "artifact_sha256": "",
        },
    }
    target = result["target_mac"]
    assert isinstance(target, dict)

    memory_id: str | None = None
    document_id: str | None = None
    conversation_id: str | None = None
    try:
        _open_app(app)
        if not _wait_ready(args.base_url, api_key):
            raise RuntimeError("managed_core_not_ready")

        acceptance = _json_command(
            [str(core), "acceptance", "--base-url", args.base_url, "--require-model"],
            env=env,
        )
        if acceptance.get("ok") is not True or acceptance.get("fallback") is not False:
            raise RuntimeError("real_model_acceptance_failed")
        target["provider"] = str(acceptance.get("chat_provider") or "")
        target["model"] = str(acceptance.get("chat_model") or "")
        target["real_model_ok"] = True
        target["fallback_false"] = True

        marker = f"lumi-ga-memory-{uuid.uuid4().hex}"
        code = f"LUMI-GA-{uuid.uuid4().hex[:12].upper()}"
        with httpx.Client(base_url=args.base_url.rstrip("/"), headers=_headers(api_key), timeout=45.0) as client:
            memory_response = client.post(
                "/v1/memories",
                json={
                    "content": f"{marker} persists across the GA restart probe.",
                    "kind": "test",
                    "title": "GA restart memory",
                    "approved_by_user": True,
                },
            )
            memory_response.raise_for_status()
            memory_id = str(memory_response.json()["memory"]["id"])

            markdown = f"# Lumi GA evidence\n\nThe exact GA verification code is `{code}`.\n"
            upload = client.post(
                "/v1/knowledge/upload",
                files={"file": ("lumi-ga-verification.md", markdown.encode(), "text/markdown")},
                data={"title": "Lumi GA verification", "source": "physical-target-mac"},
            )
            upload.raise_for_status()
            document_id = str(upload.json()["document_id"])
            chat = client.post(
                "/v1/chat",
                json={
                    "message": "What is the exact GA verification code from the Lumi GA verification document? Return the code and cite the source.",
                },
            )
            chat.raise_for_status()
            chat_payload = chat.json()
            conversation_id = str(chat_payload.get("conversation_id") or "") or None
            citation_ids = {str(item.get("document_id")) for item in chat_payload.get("citations", []) if isinstance(item, dict)}
            if chat_payload.get("fallback") is not False or document_id not in citation_ids or code not in str(chat_payload.get("content") or ""):
                raise RuntimeError("grounded_real_model_citation_failed")
            target["grounded_citation_ok"] = True

        port = _port(args.base_url)
        before_pids = _listener_pids(port)
        if not before_pids:
            raise RuntimeError("managed_core_listener_pid_not_found")
        _quit_app()
        if not _wait_ready(args.base_url, api_key, timeout=30.0, expected=False):
            raise RuntimeError("core_did_not_stop_with_app")
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline and any(_process_exists(pid) for pid in before_pids):
            time.sleep(0.25)
        if any(_process_exists(pid) for pid in before_pids):
            raise RuntimeError("app_owned_core_process_survived_quit")
        target["shutdown_ownership_ok"] = True

        _open_app(app)
        if not _wait_ready(args.base_url, api_key):
            raise RuntimeError("managed_core_not_ready_after_restart")
        target["restart_ok"] = True

        with httpx.Client(base_url=args.base_url.rstrip("/"), headers=_headers(api_key), timeout=30.0) as client:
            memory_search = client.post("/v1/memories/search", json={"query": marker, "k": 6})
            memory_search.raise_for_status()
            if not any(str(hit.get("memory_id")) == memory_id for hit in memory_search.json().get("hits", [])):
                raise RuntimeError("durable_memory_missing_after_restart")
            target["durable_memory_ok"] = True

        with tempfile.TemporaryDirectory(prefix="lumi-ga-") as temp:
            tmp = Path(temp)
            read_ok, write_ok = asyncio.run(_verify_tool_boundary(tmp))
            target["read_tool_ok"] = read_ok
            target["approval_gated_write_ok"] = write_ok
            if not read_ok or not write_ok:
                raise RuntimeError("tool_boundary_probe_failed")

            backup = _json_command([str(core), "backup", "--directory", str(tmp), "--prefix", "ga", "--full"], env=env)
            backup_path = Path(str(backup.get("backup") or ""))
            if backup.get("ok") is not True or not backup_path.exists():
                raise RuntimeError("ga_backup_failed")
            target["backup_restore_copy_ok"] = _restore_copy(core, backup_path, tmp, api_key)
            if target["backup_restore_copy_ok"] is not True:
                raise RuntimeError("backup_restore_copy_failed")

        required = [
            "real_model_ok", "fallback_false", "restart_ok", "durable_memory_ok", "grounded_citation_ok",
            "read_tool_ok", "approval_gated_write_ok", "backup_restore_copy_ok", "shutdown_ownership_ok",
        ]
        target["ok"] = all(target.get(key) is True for key in required)
    except Exception as exc:
        target["error"] = f"{type(exc).__name__}:{exc}"
    finally:
        try:
            with httpx.Client(base_url=args.base_url.rstrip("/"), headers=_headers(api_key), timeout=10.0) as client:
                if memory_id:
                    client.delete(f"/v1/memories/{memory_id}")
                if document_id:
                    client.delete(f"/v1/knowledge/documents/{document_id}")
                if conversation_id:
                    client.delete(f"/v1/conversations/{conversation_id}")
        except Exception:
            pass
        output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(json.dumps({"ok": target.get("ok") is True, "evidence": str(output), "target_mac": target}, indent=2, sort_keys=True))
    return 0 if target.get("ok") is True else 1


if __name__ == "__main__":
    raise SystemExit(main())
