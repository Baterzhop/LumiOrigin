from __future__ import annotations

from pathlib import Path
import os

import pytest

from lumi_core.cli import main as cli_main
from lumi_core.storage.database import Database
from lumi_core.storage.maintenance import DatabaseMaintenance


def _clear_lumi_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in list(os.environ):
        if name.startswith("LUMI_"):
            monkeypatch.delenv(name, raising=False)


def test_restore_round_trip_creates_safety_backup(tmp_path):
    database = Database(tmp_path / "lumi.sqlite3")
    database.migrate()
    conversation_id = database.create_conversation("before")
    database.add_message(conversation_id, "user", "original")

    maintenance = DatabaseMaintenance(database)
    backup = maintenance.create_backup(tmp_path / "backups", prefix="manual")

    database.add_message(conversation_id, "assistant", "later mutation")
    assert len(database.list_messages(conversation_id)) == 2

    result = maintenance.restore_backup(backup, safety_directory=tmp_path / "backups")
    assert result.restored_from == backup.resolve()
    assert result.safety_backup is not None and result.safety_backup.exists()
    restored = database.list_messages(conversation_id)
    assert len(restored) == 1
    assert restored[0]["content"] == "original"


def test_restore_rejects_invalid_database(tmp_path):
    database = Database(tmp_path / "lumi.sqlite3")
    database.migrate()
    invalid = tmp_path / "invalid.sqlite3"
    invalid.write_bytes(b"not sqlite")
    with pytest.raises(Exception):
        DatabaseMaintenance(database).restore_backup(invalid)


def test_cli_doctor_can_initialize_without_model(monkeypatch, tmp_path, capsys):
    _clear_lumi_env(monkeypatch)
    monkeypatch.setenv("LUMI_DATA_DIR", str(tmp_path / "data"))
    result = cli_main(["doctor", "--initialize", "--no-model", "--require-database"])
    captured = capsys.readouterr()
    assert result == 0
    assert '"ok": true' in captured.out.lower()
    assert (tmp_path / "data" / "lumi.sqlite3").exists()


def test_cli_refuses_non_loopback_serve_without_api_key(monkeypatch, tmp_path, capsys):
    _clear_lumi_env(monkeypatch)
    monkeypatch.setenv("LUMI_DATA_DIR", str(tmp_path / "data"))
    result = cli_main(["serve", "--host", "0.0.0.0", "--port", "8790"])
    captured = capsys.readouterr()
    assert result == 2
    assert "Refusing non-loopback bind" in captured.err


def test_project_console_script_is_declared():
    pyproject = Path(__file__).resolve().parents[1] / "pyproject.toml"
    text = pyproject.read_text(encoding="utf-8")
    assert 'lumi-core = "lumi_core.cli:main"' in text
