from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import os
import sqlite3

from .database import Database


class DatabaseMaintenance:
    def __init__(self, database: Database):
        self.database = database

    def integrity_check(self, *, full: bool = False) -> tuple[bool, str]:
        return self.verify_sqlite(self.database.path, full=full)

    @staticmethod
    def verify_sqlite(path: Path, *, full: bool = False) -> tuple[bool, str]:
        path = path.expanduser()
        if not path.exists():
            return False, "database_missing"
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            pragma = "integrity_check" if full else "quick_check"
            rows = [str(row[0]) for row in connection.execute(f"PRAGMA {pragma}").fetchall()]
        finally:
            connection.close()
        if rows == ["ok"]:
            return True, "ok"
        return False, "; ".join(rows[:20]) or "integrity_check_failed"

    def create_backup(self, directory: Path, *, prefix: str = "lumi") -> Path:
        source_path = self.database.path
        if not source_path.exists() or source_path.stat().st_size == 0:
            raise FileNotFoundError("database_not_initialized")

        directory = directory.expanduser()
        directory.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        destination = directory / f"{prefix}-{stamp}.sqlite3"
        self._copy_sqlite(source_path, destination)
        return destination

    def restore_backup(
        self,
        backup_path: Path,
        *,
        pre_restore_directory: Path | None = None,
        prefix: str = "pre-restore",
    ) -> Path | None:
        backup_path = backup_path.expanduser().resolve()
        destination = self.database.path.expanduser().resolve()
        if backup_path == destination:
            raise ValueError("backup_must_not_be_live_database")
        ok, detail = self.verify_sqlite(backup_path, full=True)
        if not ok:
            raise RuntimeError(f"backup_integrity_check_failed:{detail}")

        pre_restore_backup: Path | None = None
        if destination.exists() and destination.stat().st_size > 0:
            pre_restore_directory = (pre_restore_directory or destination.parent / "backups").expanduser()
            pre_restore_backup = self.create_backup(pre_restore_directory, prefix=prefix)

        destination.parent.mkdir(parents=True, exist_ok=True)
        temp = destination.with_name(destination.name + ".restore-tmp")
        temp.unlink(missing_ok=True)
        try:
            self._copy_sqlite(backup_path, temp)
            for suffix in ("-wal", "-shm"):
                Path(str(destination) + suffix).unlink(missing_ok=True)
            os.replace(temp, destination)
            try:
                os.chmod(destination, 0o600)
            except OSError:
                pass
        except Exception:
            temp.unlink(missing_ok=True)
            raise

        ok, detail = self.integrity_check(full=True)
        if not ok:
            raise RuntimeError(f"restored_database_integrity_failed:{detail}")
        return pre_restore_backup

    @staticmethod
    def prune_backups(directory: Path, *, keep: int, prefix: str = "lumi") -> list[Path]:
        keep = max(1, keep)
        directory = directory.expanduser()
        if not directory.exists():
            return []
        backups = sorted(
            directory.glob(f"{prefix}-*.sqlite3"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        removed: list[Path] = []
        for path in backups[keep:]:
            try:
                path.unlink()
                removed.append(path)
            except FileNotFoundError:
                continue
        return removed

    @classmethod
    def _copy_sqlite(cls, source_path: Path, destination: Path) -> None:
        source_path = source_path.expanduser()
        destination = destination.expanduser()
        destination.parent.mkdir(parents=True, exist_ok=True)
        source = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True)
        target = sqlite3.connect(destination)
        try:
            source.backup(target)
            row = target.execute("PRAGMA quick_check").fetchone()
            if not row or str(row[0]) != "ok":
                raise RuntimeError("backup_integrity_check_failed")
        except Exception:
            target.close()
            source.close()
            destination.unlink(missing_ok=True)
            raise
        else:
            target.close()
            source.close()
        try:
            os.chmod(destination, 0o600)
        except OSError:
            pass
