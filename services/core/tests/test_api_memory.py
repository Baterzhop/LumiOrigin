from fastapi.testclient import TestClient

from lumi_core.api.main import create_app


def test_memory_api_requires_explicit_approval_and_supports_crud():
    client = TestClient(create_app())
    payload = {
        "content": "API memory approval probe lunar-4821",
        "kind": "note",
        "title": "Approval probe",
        "approved_by_user": False,
    }
    denied = client.post("/v1/memories", json=payload)
    assert denied.status_code == 400
    assert denied.json()["detail"] == "explicit_user_approval_required"

    payload["approved_by_user"] = True
    created = client.post("/v1/memories", json=payload)
    assert created.status_code == 200
    memory = created.json()["memory"]
    memory_id = memory["id"]
    assert memory["approved"] is True

    updated = client.patch(
        f"/v1/memories/{memory_id}",
        json={"content": "API memory approval probe lunar-4821 updated", "kind": "note"},
    )
    assert updated.status_code == 200
    assert "updated" in updated.json()["memory"]["content"]

    deleted = client.delete(f"/v1/memories/{memory_id}")
    assert deleted.status_code == 200
    assert deleted.json()["deleted"] is True

    missing = client.patch(f"/v1/memories/{memory_id}", json={"content": "should not exist"})
    assert missing.status_code == 404
