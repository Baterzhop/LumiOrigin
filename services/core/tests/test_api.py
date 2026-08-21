from fastapi.testclient import TestClient
from lumi_core.api.main import create_app


def test_health():
    response = TestClient(create_app()).get("/health")
    assert response.status_code == 200
    assert response.json()["service"] == "lumi-core"
