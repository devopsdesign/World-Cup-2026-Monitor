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
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

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
REFRESH_ATTEMPTS = Counter("wc_upstream_refresh_attempts_total", "Upstream refresh attempts")
REFRESH_SUCCESSES = Counter("wc_upstream_refresh_successes_total", "Successful upstream refreshes")
UPSTREAM_MATCHES = Gauge("wc_tournament_matches_count", "Matches returned by the tournament API")
COMPLETED_MATCHES = Gauge("wc_completed_matches_count", "Completed matches in the tournament")
AVG_GOALS_PER_MATCH = Gauge("wc_average_goals_per_match", "Average goals across tournament matches")
HIGH_SCORING_MATCHES = Gauge("wc_high_scoring_matches_count", "Matches with four or more goals")
MAX_WIN_MARGIN = Gauge("wc_largest_margin_of_victory_goals", "Largest winning margin in the tournament")
LAST_REFRESH = Gauge("wc_last_successful_refresh_timestamp_seconds", "Unix timestamp of the last successful refresh")
CACHE_AGE = Gauge("wc_cache_age_seconds", "Age of the cached live-match response in seconds")
REFRESH_DURATION = Histogram("wc_upstream_refresh_duration_seconds", "Duration of an upstream refresh")

_cache: dict[str, Any] = {"live": [], "stats": {}, "updated_at": 0, "errors": 0}
_cache_lock = asyncio.Lock()


def _register_default_metrics() -> None:
    LIVE_MATCHES.set(0.0)
    TOTAL_GOALS.set(0.0)
    MATCH_INTENSITY.set(0.0)
    UPSTREAM_ERRORS.set(0.0)
    UPSTREAM_MATCHES.set(0.0)
    COMPLETED_MATCHES.set(0.0)
    AVG_GOALS_PER_MATCH.set(0.0)
    HIGH_SCORING_MATCHES.set(0.0)
    MAX_WIN_MARGIN.set(0.0)
    LAST_REFRESH.set(0.0)
    CACHE_AGE.set(0.0)


_register_default_metrics()


def _compute_summary(live_matches: list[dict[str, Any]], all_matches: list[dict[str, Any]]) -> dict[str, float]:
    total_matches = len(all_matches) if isinstance(all_matches, list) else 0
    completed_matches = sum(1 for m in all_matches if (m or {}).get("status") == "completed") if isinstance(all_matches, list) else 0

    total_goals = 0
    high_scoring_matches = 0
    largest_margin = 0

    if isinstance(all_matches, list):
        for match in all_matches:
            if not isinstance(match, dict):
                continue
            home_goals = int((match.get("home_team") or {}).get("goals") or 0)
            away_goals = int((match.get("away_team") or {}).get("goals") or 0)
            total_goals += home_goals + away_goals
            if home_goals + away_goals >= 4:
                high_scoring_matches += 1
            margin = abs(home_goals - away_goals)
            if margin > largest_margin:
                largest_margin = margin

    live_count = len(live_matches) if isinstance(live_matches, list) else 0
    avg_goals = (total_goals / total_matches) if total_matches else 0.0

    return {
        "live_matches": float(live_count),
        "total_matches": float(total_matches),
        "completed_matches": float(completed_matches),
        "total_goals": float(total_goals),
        "average_goals_per_match": float(avg_goals),
        "high_scoring_matches": float(high_scoring_matches),
        "largest_margin_of_victory": float(largest_margin),
    }


async def _refresh_once(client: httpx.AsyncClient) -> None:
    REFRESH_ATTEMPTS.inc()
    started_at = time.monotonic()
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
        summary = _compute_summary(live_data, all_matches if isinstance(all_matches, list) else [])

        LIVE_MATCHES.set(summary["live_matches"])
        TOTAL_GOALS.set(summary["total_goals"])
        MATCH_INTENSITY.set(intensity)
        UPSTREAM_MATCHES.set(summary["total_matches"])
        COMPLETED_MATCHES.set(summary["completed_matches"])
        AVG_GOALS_PER_MATCH.set(summary["average_goals_per_match"])
        HIGH_SCORING_MATCHES.set(summary["high_scoring_matches"])
        MAX_WIN_MARGIN.set(summary["largest_margin_of_victory"])
        REFRESH_SUCCESSES.inc()
        refreshed_at = time.time()
        LAST_REFRESH.set(refreshed_at)
        REFRESH_DURATION.observe(time.monotonic() - started_at)

        async with _cache_lock:
            _cache["live"] = live_data
            _cache["updated_at"] = refreshed_at
            # Everything the 10 frontend tiles need, in one JSON payload —
            # the browser reads this from /api/live and never scrapes the
            # Prometheus exposition format itself.
            _cache["stats"] = {
                **summary,
                "match_intensity": intensity,
                "upstream_errors": _cache["errors"],
                "last_refresh": refreshed_at,
            }
    except Exception as exc:  # noqa: BLE001 - one bad poll must never crash the loop
        UPSTREAM_ERRORS.inc()
        REFRESH_DURATION.observe(time.monotonic() - started_at)
        async with _cache_lock:
            _cache["errors"] += 1
            if _cache["stats"]:
                _cache["stats"]["upstream_errors"] = _cache["errors"]
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
                "stats": _cache["stats"],
                "updated_at": _cache["updated_at"],
                "upstream_errors": _cache["errors"],
            }
        )


@app.get("/metrics")
async def metrics() -> PlainTextResponse:
    # Only derived, request-time values are set here. The tournament
    # gauges are owned exclusively by _refresh_once() — resetting them on
    # every scrape (as an earlier version did) blanked the dashboard and
    # the frontend tiles between refreshes.
    async with _cache_lock:
        updated_at = _cache["updated_at"]
    CACHE_AGE.set(max(0.0, time.time() - updated_at) if updated_at else 0.0)
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


# Static frontend last, so /api and /metrics above take precedence.
app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")
