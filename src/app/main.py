"""World Cup 2026 Monitor — web app.

One small, free-tier-friendly service that does three jobs so we don't
need three separate pods on a t3.micro:

  * serves the soccer-themed static frontend (./static)
  * exposes a small JSON API the frontend polls for live scores
  * exposes /metrics for Prometheus (kept API-compatible with the
    original wc_live_matches_count / wc_total_goals_count /
    wc_live_match_intensity gauges so the existing Grafana dashboard
    keeps working unchanged)

Upstream data comes from the public https://worldcupjson.net API. All
outbound calls are timeout-bounded and failures are swallowed into the
existing cache so a flaky upstream never takes the whole app down.
"""

import asyncio
import logging
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from prometheus_client import CONTENT_TYPE_LATEST, Gauge, generate_latest

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("worldcup")

UPSTREAM_BASE = "https://worldcupjson.net"
REFRESH_SECONDS = 30
HTTP_TIMEOUT = httpx.Timeout(10.0, connect=5.0)
STATIC_DIR = Path(__file__).parent / "static"

# --- Prometheus metrics (names kept stable for the existing dashboard) ---
LIVE_MATCHES = Gauge("wc_live_matches_count", "Number of matches currently live")
TOTAL_GOALS = Gauge("wc_total_goals_count", "Total goals scored in the tournament")
MATCH_INTENSITY = Gauge("wc_live_match_intensity", "Live match action intensity index")
UPSTREAM_ERRORS = Gauge("wc_upstream_errors_total", "Upstream API calls that failed since start")

_cache: dict[str, Any] = {"live": [], "updated_at": 0, "errors": 0}
_cache_lock = asyncio.Lock()


async def _refresh_once(client: httpx.AsyncClient) -> None:
    try:
        live_res = await client.get(f"{UPSTREAM_BASE}/matches/current")
        live_data = live_res.json() if live_res.status_code == 200 else []
        if not isinstance(live_data, list):
            live_data = []

        intensity = sum(
            len(m.get("home_team_events", []) or []) + len(m.get("away_team_events", []) or [])
            for m in live_data
        )

        all_res = await client.get(f"{UPSTREAM_BASE}/matches")
        all_matches = all_res.json() if all_res.status_code == 200 else []
        goals = 0
        if isinstance(all_matches, list):
            goals = sum(
                ((m.get("home_team", {}) or {}).get("goals", 0) or 0)
                + ((m.get("away_team", {}) or {}).get("goals", 0) or 0)
                for m in all_matches
                if m.get("status") in ("completed", "in_progress")
            )

        LIVE_MATCHES.set(len(live_data))
        TOTAL_GOALS.set(goals)
        MATCH_INTENSITY.set(intensity)

        async with _cache_lock:
            _cache["live"] = live_data
            _cache["updated_at"] = time.time()
    except Exception as exc:  # noqa: BLE001 - one bad poll must never crash the loop
        UPSTREAM_ERRORS.inc()
        async with _cache_lock:
            _cache["errors"] += 1
        log.warning("upstream refresh failed: %s", exc)


async def _refresh_loop() -> None:
    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
        while True:
            await _refresh_once(client)
            await asyncio.sleep(REFRESH_SECONDS)


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(_refresh_loop())
    try:
        yield
    finally:
        task.cancel()


app = FastAPI(title="World Cup 2026 Monitor", lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> dict:
    return {"status": "ok"}


@app.get("/api/live")
async def api_live() -> JSONResponse:
    async with _cache_lock:
        return JSONResponse(
            {
                "matches": _cache["live"],
                "updated_at": _cache["updated_at"],
                "upstream_errors": _cache["errors"],
            }
        )


@app.get("/metrics")
async def metrics() -> PlainTextResponse:
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


# Static frontend last, so /api and /metrics above take precedence.
app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")
