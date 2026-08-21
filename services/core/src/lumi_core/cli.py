from __future__ import annotations

import argparse
import json
from pathlib import Path
import tempfile
from urllib.parse import urlparse

import httpx

from lumi_core import __version__
from lumi_core.config import Settings
from lumi_core.storage.database import Database
from lumi_core.storage.maintenance import DatabaseMaintenance


def _writable_directory(path: Path) -> tuple[bool, str]:
    try:
        path = path.expanduser()
        path.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(prefix=".lumi-write-test-", dir=path, delete=True):
            pass
        return True, "ok"
    except Exception as exc:
        return False, f"{type(exc).__name__}:{exc}"


def _ollama_health(url: str, timeout: float = 2.0) -> tuple[bool, str]:
    parsed = urlparse(url)
    origin = f"{parsed.scheme}://{parsed.netloc}"
    try:
        response = httpx.get(origin + "/api/tags", timeout=timeout)
        if 200 <= response.status_code < 300:
            return True, "ok"
        return False, f"http_{response.status_code}"
    except Exception as exc:
        return False, type(exc).__name__


def doctor(args: argparse.Namespace) -> int:
    settings = Settings.from_env()
    database = Database(settings.database_path)
    if args.initialize:
        database.migrate()

    maintenance = DatabaseMaintenance(database)
    checks: list[dict] = []

    db_ok, db_detail = maintenance.integrity_check(full=args.full_check)
    checks.append({"name": "database", "ok": db_ok, "detail": db_detail, "critical": True})

    for name, path in (
        ("database_directory", settings.database_path.parent),
        ("backup_directory", settings.backup_dir),
        ("tool_workspace", settings.tool_workspace_root),
    ):
        ok, detail = _writable_directory(path)
        checks.append({"name": name, "ok": ok, "detail": detail, "critical": True})

    if not args.skip_model:
        model_ok, model_detail = _ollama_health(settings.ollama_url, timeout=min(5.0, settings.model_timeout_seconds))
        checks.append({"name": "ollama", "ok": model_ok, "detail": model_detail, "critical": bool(args.strict)})

    payload = {
        "service": "lumi-core",
        "version": __version__,
        "database": str(settings.database_path),
        "api_auth": "configured" if settings.api_key else "loopback-only",
        "checks": checks,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"Lumi Core {__version__}")
        for item in checks:
            mark = "OK" if item["ok"] else ("FAIL" if item["critical"] else "WARN")
            print(f"[{mark:4}] {item['name']}: {item['detail']}")

    failed = [item for item in checks if item["critical"] and not item["ok"]]
    return 1 if failed else 0


def backup(args: argparse.Namespace) -> int:
    settings = Settings.from_env()
    database = Database(settings.database_path)
    maintenance = DatabaseMaintenance(database)
    ok, detail = maintenance.integrity_check(full=args.full_check)
    if not ok:
        raise SystemExit(f"Refusing backup: database integrity check failed: {detail}")
    path = maintenance.create_backup(settings.backup_dir)
    maintenance.prune_backups(settings.backup_dir, keep=settings.backup_keep)
    print(path)
    return 0


def restore(args: argparse.Namespace) -> int:
    if not args.yes:
        raise SystemExit("Restore is destructive. Re-run with --yes after verifying the backup path.")
    settings = Settings.from_env()
    database = Database(settings.database_path)
    maintenance = DatabaseMaintenance(database)
    source = Path(args.backup).expanduser()
    pre_restore = maintenance.restore_backup(source, pre_restore_directory=settings.backup_dir)
    print(f"restored={settings.database_path}")
    if pre_restore:
        print(f"pre_restore_backup={pre_restore}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lumi-core", description="Lumi Core operational CLI")
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command", required=True)

    doctor_parser = sub.add_parser("doctor", help="Validate local configuration, storage and model connectivity.")
    doctor_parser.add_argument("--initialize", action="store_true", help="Apply migrations before diagnostics.")
    doctor_parser.add_argument("--full-check", action="store_true", help="Use SQLite integrity_check instead of quick_check.")
    doctor_parser.add_argument("--skip-model", action="store_true", help="Do not probe Ollama.")
    doctor_parser.add_argument("--strict", action="store_true", help="Treat Ollama unavailability as a failure.")
    doctor_parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    doctor_parser.set_defaults(func=doctor)

    backup_parser = sub.add_parser("backup", help="Create a verified SQLite backup.")
    backup_parser.add_argument("--full-check", action="store_true")
    backup_parser.set_defaults(func=backup)

    restore_parser = sub.add_parser("restore", help="Restore a verified SQLite backup.")
    restore_parser.add_argument("backup", help="Path to a Lumi SQLite backup.")
    restore_parser.add_argument("--yes", action="store_true", help="Required explicit destructive-operation acknowledgement.")
    restore_parser.set_defaults(func=restore)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
