from __future__ import annotations

import argparse

from lumi_core.config import Settings
from lumi_core.storage.database import Database
from lumi_core.storage.maintenance import DatabaseMaintenance


def main() -> int:
    parser = argparse.ArgumentParser(description="Create and verify a Lumi SQLite backup.")
    parser.add_argument("--full-check", action="store_true", help="Run SQLite integrity_check before backup.")
    args = parser.parse_args()

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


if __name__ == "__main__":
    raise SystemExit(main())
