from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlparse

import httpx
import uvicorn

from lumi_core import __version__
from lumi_core.config import Settings
from lumi_core.storage.database import Database
from lumi_core.storage.maintenance import DatabaseMaintenance


def _json_print(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


def _settings_or_exit() -> Settings:
    try:
        return Settings.from_env()
    except Exception as exc:
        _json_print({"ok": False, "stage": "configuration", "error": str(exc)})
        raise SystemExit(2) from exc


def _database(settings: Settings) -> Database:
    return Database(settings.database_path)


def _initialize_database(settings: Settings, *, backup: bool = True) -> Database:
    database = _database(settings)
    maintenance = DatabaseMaintenance(database)
    if database.path.exists() and database.path.stat().st_size > 0 and backup and settings.backup_before_migrate:
        backup_path = maintenance.create_backup(settings.backup_dir, prefix="pre-migrate")
        maintenance.prune_backups(settings.backup_dir, keep=settings.backup_keep, prefix="pre-migrate")
        print(f"Created pre-migration backup: {backup_path}", file=sys.stderr)
    database.migrate()
    ok, detail = maintenance.integrity_check()
    if not ok:
        raise RuntimeError(f"database_integrity_failed:{detail}")
    return database


def _ollama_tags_url(chat_url: str) -> str:
    parsed = urlparse(chat_url)
    path = parsed.path or "/"
    if path.endswith("/api/chat"):
        path = path[: -len("/api/chat")] + "/api/tags"
    elif "/api/" in path:
        path = path.rsplit("/api/", 1)[0] + "/api/tags"
    else:
        path = "/api/tags"
    return parsed._replace(path=path, params="", query="", fragment="").geturl()


def _model_probe(settings: Settings) -> tuple[bool, str]:
    url = _ollama_tags_url(settings.ollama_url)
    try:
        response = httpx.get(url, timeout=min(settings.model_timeout_seconds, 5.0))
        response.raise_for_status()
        payload = response.json()
        models = payload.get("models") if isinstance(payload, dict) else None
        if isinstance(models, list):
            names = {
                str(item.get("name") or item.get("model") or "")
                for item in models
                if isinstance(item, dict)
            }
            if settings.ollama_model not in names and not any(
                name.startswith(settings.ollama_model + ":") for name in names
            ):
                return False, f"model_not_listed:{settings.ollama_model}"
        return True, "ok"
    except Exception as exc:
        return False, type(exc).__name__


def command_doctor(args: argparse.Namespace) -> int:
    settings = _settings_or_exit()
    database = _database(settings)
    result: dict[str, object] = {
        "ok": True,
        "version": __version__,
        "configuration": "ok",
        "database": {},
        "model": {},
        "paths": {
            "database": str(settings.database_path),
            "backup_dir": str(settings.backup_dir),
            "workspace": str(settings.tool_workspace_root),
        },
    }

    if args.initialize:
        try:
            _initialize_database(settings)
        except Exception as exc:
            result["ok"] = False
            result["database"] = {"status": "initialization_failed", "detail": str(exc)}
            _json_print(result)
            return 1

    if database.path.exists() and database.path.stat().st_size > 0:
        ok, detail = DatabaseMaintenance(database).integrity_check(full=args.full)
        result["database"] = {"status": "ok" if ok else "failed", "detail": detail}
        result["ok"] = bool(result["ok"]) and ok
    else:
        result["database"] = {"status": "not_initialized"}
        if args.require_database:
            result["ok"] = False

    if args.no_model:
        result["model"] = {"status": "skipped"}
    else:
        model_ok, model_detail = _model_probe(settings)
        result["model"] = {
            "status": "ok" if model_ok else "unavailable",
            "detail": model_detail,
            "model": settings.ollama_model,
        }
        if args.require_model:
            result["ok"] = bool(result["ok"]) and model_ok

    _json_print(result)
    return 0 if result["ok"] else 1


def command_migrate(args: argparse.Namespace) -> int:
    settings = _settings_or_exit()
    try:
        database = _initialize_database(settings, backup=not args.no_backup)
    except Exception as exc:
        _json_print({"ok": False, "error": str(exc)})
        return 1
    maintenance = DatabaseMaintenance(database)
    ok, detail = maintenance.integrity_check(full=args.full)
    _json_print({"ok": ok, "database": str(database.path), "integrity": detail})
    return 0 if ok else 1


def command_backup(args: argparse.Namespace) -> int:
    settings = _settings_or_exit()
    database = _database(settings)
    maintenance = DatabaseMaintenance(database)
    try:
        ok, detail = maintenance.integrity_check(full=args.full)
        if not ok:
            raise RuntimeError(f"source_database_integrity_failed:{detail}")
        destination = maintenance.create_backup(
            Path(args.directory).expanduser() if args.directory else settings.backup_dir,
            prefix=args.prefix,
        )
    except Exception as exc:
        _json_print({"ok": False, "error": str(exc)})
        return 1
    _json_print({"ok": True, "backup": str(destination), "database": str(database.path)})
    return 0


def command_restore(args: argparse.Namespace) -> int:
    if not args.yes:
        print("Restore is destructive. Re-run with --yes after stopping Lumi Core.", file=sys.stderr)
        return 2
    settings = _settings_or_exit()
    database = _database(settings)
    maintenance = DatabaseMaintenance(database)
    try:
        result = maintenance.restore_backup(
            Path(args.backup).expanduser(),
            safety_directory=settings.backup_dir,
            full_check=args.full,
        )
    except Exception as exc:
        _json_print({"ok": False, "error": str(exc)})
        return 1
    _json_print(
        {
            "ok": True,
            "database": str(database.path),
            "restored_from": str(result.restored_from),
            "safety_backup": str(result.safety_backup) if result.safety_backup else None,
        }
    )
    return 0


def command_serve(args: argparse.Namespace) -> int:
    settings = _settings_or_exit()
    host = args.host
    if not 1 <= args.port <= 65535:
        print("Port must be between 1 and 65535.", file=sys.stderr)
        return 2
    if settings.api_key is None and host not in {"127.0.0.1", "::1", "localhost"}:
        print(
            "Refusing non-loopback bind without LUMI_API_KEY. Configure a strong key first.",
            file=sys.stderr,
        )
        return 2
    uvicorn.run(
        "lumi_core.api.main:app",
        host=host,
        port=args.port,
        log_level=args.log_level,
        access_log=False,
    )
    return 0


def command_version(_: argparse.Namespace) -> int:
    print(__version__)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lumi-core", description="Lumi V4 Core operations CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    version = sub.add_parser("version", help="Print Lumi Core version")
    version.set_defaults(func=command_version)

    doctor = sub.add_parser("doctor", help="Validate local configuration, database and model availability")
    doctor.add_argument("--initialize", action="store_true", help="Initialize/migrate the database before checking it")
    doctor.add_argument("--require-database", action="store_true", help="Fail when the database has not been initialized")
    doctor.add_argument("--require-model", action="store_true", help="Fail if the configured local model is unavailable")
    doctor.add_argument("--no-model", action="store_true", help="Skip the local model probe")
    doctor.add_argument("--full", action="store_true", help="Use SQLite integrity_check instead of quick_check")
    doctor.set_defaults(func=command_doctor)

    migrate = sub.add_parser("migrate", help="Apply database migrations with a pre-migration backup")
    migrate.add_argument("--no-backup", action="store_true", help="Skip the pre-migration safety backup")
    migrate.add_argument("--full", action="store_true", help="Run a full SQLite integrity check after migration")
    migrate.set_defaults(func=command_migrate)

    backup = sub.add_parser("backup", help="Create and verify a consistent SQLite backup")
    backup.add_argument("--directory", help="Backup directory; defaults to LUMI_BACKUP_DIR")
    backup.add_argument("--prefix", default="manual", help="Backup filename prefix")
    backup.add_argument("--full", action="store_true", help="Full integrity check before backup")
    backup.set_defaults(func=command_backup)

    restore = sub.add_parser("restore", help="Restore a verified SQLite backup")
    restore.add_argument("backup", help="Path to the SQLite backup")
    restore.add_argument("--yes", action="store_true", help="Acknowledge destructive restore")
    restore.add_argument("--full", action="store_true", help="Use full integrity checks")
    restore.set_defaults(func=command_restore)

    serve = sub.add_parser("serve", help="Run Lumi Core")
    serve.add_argument("--host", default=os.getenv("LUMI_HOST", "127.0.0.1"))
    serve.add_argument("--port", type=int, default=int(os.getenv("LUMI_PORT", "8790")))
    serve.add_argument("--log-level", default=os.getenv("LUMI_LOG_LEVEL", "info"))
    serve.set_defaults(func=command_serve)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "require_model", False) and getattr(args, "no_model", False):
        parser.error("--require-model and --no-model cannot be used together")
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
