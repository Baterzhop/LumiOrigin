from __future__ import annotations

from pathlib import Path
import sqlite3

import pytest

from lumi_core.cli import build_parser, doctor
from lumi_core.storage.database import Database
from lumi_core.storage.maintenance import DatabaseMaintenance


def test_restore_backup_round_trip_and_preserves_pre_restore_copy(tmp_path: Path):
    live = tmp_path / "live.sqlite3"
    backups = tmp_path / "backups"
    database = Database(live)
    database.migrate()
    original = database.create_conversation(title="before")

    maintenance = DatabaseMaintenance(database)
    backup = maintenance.create_backup(backups)
    added_after_backup = database.create_conversation(title="after")

    pre_restore = maintenance.restore_backup(backup, pre_restore_directory=backups)
    assert pre_restore is not None and pre_restore.exists()
    assert maintenance.integrity_check(full=True) == (True, "ok")

    with sqlite3.connect(live) as connection:
        ids = {row[0] for row in connection.execute("SELECT id FROM conversations")}
    assert original in ids
    assert added_after_backup not in ids

    with sqlite3.connect(pre_restore) as connection:
        pre_restore_ids = {row[0] for row in connection.execute("SELECT id FROM conversations")}
    assert added_after_backup in pre_restore_ids


def test_restore_rejects_invalid_sqlite(tmp_path: Path):
    database = Database(tmp_path / "live.sqlite3")
    database.migrate()
    invalid = tmp_path / "invalid.sqlite3"
    invalid.write_text("not sqlite", encoding="utf-8")
    with pytest.raises(Exception):
        DatabaseMaintenance(database).restore_backup(invalid)


def test_cli_doctor_can_initialize_clean_database(monkeypatch, tmp_path: Path, capsys):
    data_dir = tmp_path / "data"
    monkeypatch.setenv("LUMI_DATA_DIR", str(data_dir))
    monkeypatch.setenv("LUMI_DATABASE_PATH", str(data_dir / "lumi.sqlite3"))
    monkeypatch.setenv("LUMI_BACKUP_DIR", str(data_dir / "backups"))
    monkeypatch.setenv("LUMI_TOOL_WORKSPACE", str(data_dir / "workspace"))

    args = build_parser().parse_args(["doctor", "--initialize", "--skip-model", "--json"])
    assert doctor(args) == 0
    output = capsys.readouterr().out
    assert '"database"' in output
    assert '"ok": true' in output.lower()


def test_restore_cli_requires_explicit_yes():
    args = build_parser().parse_args(["restore", "some.sqlite3"])
    assert args.yes is False
