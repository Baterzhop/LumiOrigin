from dataclasses import replace

from fastapi.testclient import TestClient

from lumi_core.api.main import create_app
from lumi_core.config import Settings


def _settings(tmp_path, name: str) -> Settings:
    base = Settings.from_env()
    root = tmp_path / name
    return replace(
        base,
        database_path=root / "lumi.sqlite3",
        backup_dir=root / "backups",
        tool_workspace_root=root / "workspace",
        rag_dense_enabled=False,
        developer_repo_root=None,
        developer_github_repository=None,
        developer_github_token=None,
    )


def test_create_app_builds_isolated_service_graphs(tmp_path):
    first = create_app(_settings(tmp_path, "first"))
    second = create_app(_settings(tmp_path, "second"))

    assert first is not second
    assert first.state.lumi is not second.state.lumi
    assert first.state.lumi.database.path != second.state.lumi.database.path
    assert first.state.lumi.runtime is not second.state.lumi.runtime
    assert first.state.lumi.tool_registry is not second.state.lumi.tool_registry

    assert TestClient(first).get("/ready").status_code == 200
    assert TestClient(second).get("/ready").status_code == 200
