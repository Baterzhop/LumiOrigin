from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
import os
import sqlite3


@dataclass(frozen=True, slots=True)
class RestoreResult:
    restored_from: Path
    safety_backup: Path | None


class DatabaseMaintenance:
    def __init__(self, database):
        self.database = database

    @staticmethod
    def _integrity_for_path(path: Path, *, full: bool = False) -> tuple[bool, str]:
        if not path.exists() or path.stat().st_size == 0:
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

    def integrity_check(self, *, full: bool = False) -> tuple[bool, str]:
        return self._integrity_for_path(self.database.path, full=full)

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

        self._chmod_private(destination)
        return destination

    def restore_backup(
        self,
        backup_path: Path,
        *,
        safety_directory: Path | None = None,
        full_check: bool = False,
    ) -> RestoreResult:
        backup_path = backup_path.expanduser().resolve()
        target_path = self.database.path.expanduser().resolve()

        if backup_path == target_path:
            raise ValueError("backup_and_target_must_differ")
        ok, detail = self._integrity_for_path(backup_path, full=full_check)
        if not ok:
            raise RuntimeError(f"restore_source_integrity_failed:{detail}")

        target_path.parent.mkdir(parents=True, exist_ok=True)
        safety_backup: Path | None = None
        if target_path.exists() and target_path.stat().st_size > 0:
            self._assert_exclusive_access(target_path)
            safety_backup = self.create_backup(
                safety_directory or target_path.parent / "backups",
                prefix="pre-restore",
            )

        temporary = target_path.with_name(target_path.name + ".restore-tmp")
        temporary.unlink(missing_ok=True)

        source = sqlite3.connect(f"file:{backup_path}?mode=ro", uri=True)
        destination = sqlite3.connect(temporary)
        try:
            source.backup(destination)
            pragma = "integrity_check" if full_check else "quick_check"
            rows = [str(row[0]) for row in destination.execute(f"PRAGMA {pragma}").fetchall()]
            if rows != ["ok"]:
                raise RuntimeError("restored_database_integrity_failed:" + "; ".join(rows[:20]))
        except Exception:
            destination.close()
            source.close()
            temporary.unlink(missing_ok=True)
            raise
        else:
            destination.close()
            source.close()

        self._chmod_private(temporary)
        os.replace(temporary, target_path)
        Path(str(target_path) + "-wal").unlink(missing_ok=True)
        Path(str(target_path) + "-shm").unlink(missing_ok=True)

        ok, detail = self._integrity_for_path(target_path, full=full_check)
        if not ok:
            raise RuntimeError(f"restored_database_post_replace_integrity_failed:{detail}")
        return RestoreResult(restored_from=backup_path, safety_backup=safety_backup)

    @staticmethod
    def _assert_exclusive_access(path: Path) -> None:
        connection = sqlite3.connect(path, timeout=0.2)
        try:
            connection.execute("PRAGMA busy_timeout = 200")
            connection.execute("BEGIN EXCLUSIVE")
            connection.rollback()
        except sqlite3.OperationalError as exc:
            raise RuntimeError("database_in_use_stop_lumi_before_restore") from exc
        finally:
            connection.close()

    @staticmethod
    def _chmod_private(path: Path) -> None:
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

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
