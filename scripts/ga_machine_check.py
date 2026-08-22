#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import tempfile
import uuid

import httpx

from lumi_core import __version__
from lumi_core.acceptance import run_acceptance
from lumi_core.storage.database import Database
from lumi_core.storage.maintenance import DatabaseMaintenance
from lumi_core.tools import PolicyEngine, Workspace, build_default_registry


class GACheckError(RuntimeError):
    pass


def _json_response(response: httpx.Response) -> dict:
    if response.status_code != 200:
        raise GACheckError(f"{response.request.method} {response.request.url}: HTTP {response.status_code}")
    payload = response.json()
    if not isinstance(payload, dict):
        raise GACheckError("expected_json_object")
    return payload


async def _tool_boundary_check(workspace_root: Path, *, approve_write: bool) -> dict:
    workspace = Workspace(workspace_root)
    registry = build_default_registry(workspace)
    policy = PolicyEngine()

    read_tool = registry.get("workspace.list_files")
    write_tool = registry.get("workspace.write_text")
    if read_tool is None or write_tool is None:
        raise GACheckError("required_workspace_tools_missing")

    read_decision = policy.evaluate(read_tool.spec)
    if not read_decision.allowed or read_decision.requires_confirmation:
        raise GACheckError("read_tool_policy_regression")
    read_result = await registry.execute("workspace.list_files", {"path": ".", "recursive": False, "limit": 5})

    unconfirmed = policy.evaluate(write_tool.spec)
    if unconfirmed.allowed or not unconfirmed.requires_confirmation:
        raise GACheckError("write_tool_confirmation_boundary_regression")

    marker_path = f".lumi-ga/approval-{uuid.uuid4().hex}.txt"
    marker_content = "Lumi GA exact-argument approval probe\n"
    executed = False
    try:
        if approve_write:
            confirmed = policy.evaluate(write_tool.spec, user_confirmed=True)
            if not confirmed.allowed or confirmed.requires_confirmation:
                raise GACheckError("confirmed_write_not_allowed")
            result = await registry.execute(
                "workspace.write_text",
                {"path": marker_path, "content": marker_content, "overwrite": False},
            )
            created = workspace.resolve(marker_path)
            if not created.is_file() or created.read_text(encoding="utf-8") != marker_content:
                raise GACheckError("approved_write_content_mismatch")
            if result.get("path") != marker_path:
                raise GACheckError("approved_write_result_path_mismatch")
            executed = True
    finally:
        created = workspace.resolve(marker_path)
        created.unlink(missing_ok=True)
        parent = created.parent
        try:
            parent.rmdir()
        except OSError:
            pass

    return {
        "ok": True,
        "workspace": str(workspace.root),
        "read_only": {
            "allowed": True,
            "sample_entries": len(read_result.get("entries", [])),
        },
        "write_boundary": {
            "blocked_without_confirmation": True,
            "confirmation_reason": unconfirmed.reason,
            "approved_exact_write_executed": executed,
        },
    }


def _restore_probe(backup_path: Path) -> dict:
    backup_path = backup_path.expanduser().resolve()
    if not backup_path.is_file():
        raise GACheckError(f"acceptance_backup_not_accessible:{backup_path}")

    with tempfile.TemporaryDirectory(prefix="lumi-ga-restore-") as directory:
        target = Path(directory) / "restored.sqlite3"
        database = Database(target)
        maintenance = DatabaseMaintenance(database)
        result = maintenance.restore_backup(backup_path, full_check=True)
        ok, detail = maintenance.integrity_check(full=True)
        if not ok:
            raise GACheckError(f"disposable_restore_integrity_failed:{detail}")
        return {
            "ok": True,
            "source": str(result.restored_from),
            "disposable_target_verified": True,
            "integrity": detail,
        }


def run_check(args: argparse.Namespace) -> dict:
    key = os.getenv("LUMI_API_KEY", "").strip() or None
    headers = {"X-Lumi-Key": key} if key else {}
    base_url = args.base_url.rstrip("/")
    if not base_url:
        raise GACheckError("base_url_required")

    with httpx.Client(base_url=base_url, headers=headers, timeout=args.timeout) as client:
        health = _json_response(client.get("/health"))
        runtime = _json_response(client.get("/v1/runtime"))

    core_version = str(health.get("version") or "")
    if core_version and core_version != __version__:
        raise GACheckError(f"installed_script_core_version_mismatch:{__version__}:{core_version}")

    tools_state = runtime.get("tools") if isinstance(runtime.get("tools"), dict) else {}
    workspace_value = str(tools_state.get("workspace") or "").strip()
    if not workspace_value:
        raise GACheckError("runtime_workspace_missing")

    acceptance = run_acceptance(
        base_url,
        require_model=args.require_model,
        api_key=key,
        timeout_seconds=args.timeout,
    )
    backup_value = (
        acceptance.get("checks", {}).get("backup", {}).get("path")
        if isinstance(acceptance.get("checks"), dict)
        else None
    )
    if not backup_value:
        raise GACheckError("acceptance_backup_path_missing")

    restore = _restore_probe(Path(str(backup_value)))
    tools = asyncio.run(
        _tool_boundary_check(Path(workspace_value), approve_write=args.approve_tool_write)
    )

    automated_target_gate = bool(
        acceptance.get("ok")
        and (not args.require_model or acceptance.get("fallback") is False)
        and restore.get("ok")
        and tools.get("ok")
        and (
            tools["write_boundary"]["approved_exact_write_executed"]
            if args.approve_tool_write
            else tools["write_boundary"]["blocked_without_confirmation"]
        )
    )

    return {
        "schema": "lumi.ga.machine-evidence.v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "ok": automated_target_gate,
        "release_version": core_version or __version__,
        "local_runner_version": __version__,
        "machine": {
            "system": platform.system(),
            "release": platform.release(),
            "architecture": platform.machine(),
            "python": platform.python_version(),
        },
        "core": {
            "base_url": base_url,
            "provider": acceptance.get("chat_provider"),
            "model": acceptance.get("chat_model"),
            "fallback": acceptance.get("fallback"),
        },
        "acceptance": acceptance,
        "backup_restore": restore,
        "tool_policy": tools,
        "automated_target_gate_passed": automated_target_gate,
        "external_evidence_still_required": [
            "native_app_managed_core_lifecycle_and_restart",
            "durable_memory_survives_native_app_core_restart",
            "real_user_document_answer_with_verified_citation",
            "native_exact_argument_approval_ui",
            "apple_developer_id_notarization_for_public_distribution",
            "main_branch_protection",
        ],
        "ga_declared": False,
        "ga_note": "This command proves automatable machine checks only. It never declares 4.0.0 GA by itself.",
    }


def _write_private_json(path: Path, payload: dict) -> None:
    path = path.expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Collect truthful Lumi V4 physical-machine GA evidence without claiming external gates that were not run."
    )
    parser.add_argument("--base-url", default=os.getenv("LUMI_CORE_URL", "http://127.0.0.1:8790"))
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--require-model", action="store_true", help="Fail if chat or SSE falls back from the configured real model.")
    parser.add_argument(
        "--approve-tool-write",
        action="store_true",
        help="Explicitly approve a temporary exact-argument workspace.write_text probe. The marker is deleted after verification.",
    )
    parser.add_argument("--output", type=Path, help="Write the evidence JSON to a mode-0600 file as well as stdout.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.timeout <= 0:
        raise SystemExit("--timeout must be greater than zero")
    try:
        payload = run_check(args)
    except Exception as exc:
        payload = {
            "schema": "lumi.ga.machine-evidence.v1",
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "ok": False,
            "error": f"{type(exc).__name__}:{exc}",
            "ga_declared": False,
        }
        if args.output:
            _write_private_json(args.output, payload)
        print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
        return 1

    if args.output:
        _write_private_json(args.output, payload)
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
