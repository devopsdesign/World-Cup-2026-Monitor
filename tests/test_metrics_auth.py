"""/metrics is served only to a caller with the scrape token; anyone else gets a 404."""

from fastapi.testclient import TestClient

from src.app.main import app


def test_metrics_is_hidden_when_no_token_is_configured(monkeypatch):
    monkeypatch.delenv("METRICS_TOKEN", raising=False)
    assert TestClient(app).get("/metrics").status_code == 404


def test_metrics_rejects_missing_or_wrong_token(monkeypatch):
    monkeypatch.setenv("METRICS_TOKEN", "s3cret")
    client = TestClient(app)
    assert client.get("/metrics").status_code == 404
    assert client.get("/metrics", headers={"Authorization": "Bearer nope"}).status_code == 404


def test_metrics_serves_with_the_scrape_token(monkeypatch):
    monkeypatch.setenv("METRICS_TOKEN", "s3cret")
    res = TestClient(app).get("/metrics", headers={"Authorization": "Bearer s3cret"})
    assert res.status_code == 200
    assert "wc_total_goals_count" in res.text
