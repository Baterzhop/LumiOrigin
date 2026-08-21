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
        if not self.database.path.exists():
            return False, "database_missing"
        connection = sqlite3.connect(f"file:{self.database.path}?mode=ro", uri=True)
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

        source = sqlite3.connect(source_path)
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
        return destination

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
