"""World Cup 2026 Monitor — web app.

One small, free-tier-friendly service that does three jobs so we don't
need three separate pods on a t3.micro:

  * serves the soccer-themed static frontend (./static)
  * exposes a small JSON API the frontend reads for the tournament recap
  * exposes /metrics for Prometheus

Upstream data: openfootball/worldcup.json — a public-domain static JSON
file with every one of the 104 matches of the 2026 tournament (final
scores, goal scorers with minutes, groups, rounds, venues). It has no
API key and no rate limit worth worrying about at one fetch every few
hours. The original live source (worldcupjson.net) went offline and the
domain was repurposed, so there is nothing "live" to poll any more —
the tournament is complete, and this app now presents the record book.

All outbound calls are timeout-bounded and failures are swallowed into
the cache so a flaky upstream never takes the whole app down.
"""

import asyncio
import logging
import time
from collections import Counter
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from prometheus_client import CONTENT_TYPE_LATEST, Counter as PromCounter, Gauge, Histogram, generate_latest

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("worldcup")

UPSTREAM_URL = "https://raw.githubusercontent.com/openfootball/worldcup.json/master/2026/worldcup.json"
REFRESH_SECONDS = 21600  # 6h — the upstream is a static file
RETRY_SECONDS = 300      # back off to 5m after a failed fetch
HTTP_TIMEOUT = httpx.Timeout(15.0, connect=5.0)
STATIC_DIR = Path(__file__).parent / "static"

KO_ORDER = [
    "Round of 32",
    "Round of 16",
    "Quarter-final",
    "Semi-final",
    "Match for third place",
    "Final",
]

# --- Prometheus metrics ---
TOTAL_GOALS = Gauge("wc_total_goals_count", "Total goals scored in the tournament")
MATCHES_PLAYED = Gauge("wc_completed_matches_count", "Matches played in the tournament")
AVG_GOALS_PER_MATCH = Gauge("wc_average_goals_per_match", "Average goals across all matches")
HIGH_SCORING_MATCHES = Gauge("wc_high_scoring_matches_count", "Matches with four or more goals")
MAX_WIN_MARGIN = Gauge("wc_largest_margin_of_victory_goals", "Largest winning margin in a single match")
HAT_TRICKS = Gauge("wc_hat_tricks_total", "Player hat-tricks (3+ goals in a match)")
PENALTY_SHOOTOUTS = Gauge("wc_penalty_shootout_matches_total", "Matches decided by a penalty shootout")
EXTRA_TIME_MATCHES = Gauge("wc_extra_time_matches_total", "Matches that went to extra time")
GOLDEN_BOOT_GOALS = Gauge("wc_golden_boot_goals", "Goals scored by the tournament top scorer")
CHAMPION = Gauge("wc_tournament_champion_info", "1 for the winning team (see the team label)", ["team"])

UPSTREAM_ERRORS = Gauge("wc_upstream_errors_total", "Upstream fetches that failed since start")
REFRESH_ATTEMPTS = PromCounter("wc_upstream_refresh_attempts_total", "Upstream refresh attempts")
REFRESH_SUCCESSES = PromCounter("wc_upstream_refresh_successes_total", "Successful upstream refreshes")
LAST_REFRESH = Gauge("wc_last_successful_refresh_timestamp_seconds", "Unix time of the last successful refresh")
CACHE_AGE = Gauge("wc_cache_age_seconds", "Age of the cached recap in seconds")
REFRESH_DURATION = Histogram("wc_upstream_refresh_duration_seconds", "Duration of an upstream refresh")

_cache: dict[str, Any] = {"recap": {}, "updated_at": 0.0, "errors": 0}
_cache_lock = asyncio.Lock()


def _zero_metrics() -> None:
    for gauge in (
        TOTAL_GOALS, MATCHES_PLAYED, AVG_GOALS_PER_MATCH, HIGH_SCORING_MATCHES,
        MAX_WIN_MARGIN, HAT_TRICKS, PENALTY_SHOOTOUTS, EXTRA_TIME_MATCHES,
        GOLDEN_BOOT_GOALS, UPSTREAM_ERRORS, LAST_REFRESH, CACHE_AGE,
    ):
        gauge.set(0.0)


_zero_metrics()


def _final_goals(score: dict[str, Any]) -> tuple[int, int]:
    """Goals that count towards the result: end of extra time if played,
    otherwise end of regulation. A penalty shootout is *not* goals."""
    for key in ("et", "ft"):
        pair = score.get(key)
        if isinstance(pair, list) and len(pair) == 2:
            return int(pair[0] or 0), int(pair[1] or 0)
    return 0, 0


def _is_played(match: dict[str, Any]) -> bool:
    score = match.get("score") or {}
    return isinstance(score.get("ft"), list) or isinstance(score.get("et"), list)


def _is_group(match: dict[str, Any]) -> bool:
    return bool(match.get("group"))


def _winner(match: dict[str, Any]) -> str | None:
    score = match.get("score") or {}
    pens = score.get("p")
    if isinstance(pens, list) and len(pens) == 2:
        return match["team1"] if (pens[0] or 0) > (pens[1] or 0) else match["team2"]
    g1, g2 = _final_goals(score)
    if g1 > g2:
        return match["team1"]
    if g2 > g1:
        return match["team2"]
    return None


def _compute_recap(matches: list[dict[str, Any]]) -> dict[str, Any]:
    matches = [m for m in matches if isinstance(m, dict)]
    by_round = {m.get("round"): m for m in matches}

    final_m = by_round.get("Final")
    third_m = by_round.get("Match for third place")
    champion = _winner(final_m) if final_m else None
    runner_up = None
    if final_m and champion:
        runner_up = final_m["team2"] if champion == final_m["team1"] else final_m["team1"]
    third_place = _winner(third_m) if third_m else None

    played = total_goals = high_scoring = 0
    biggest = {"label": None, "margin": -1}
    highest = {"label": None, "goals": -1}
    penalty_shootouts = extra_time = 0
    scorer_goals: Counter[str] = Counter()
    hat_tricks: list[dict[str, Any]] = []

    for m in matches:
        score = m.get("score") or {}
        if isinstance(score.get("p"), list):
            penalty_shootouts += 1
        if isinstance(score.get("et"), list):
            extra_time += 1

        if not _is_played(m):
            continue
        played += 1
        g1, g2 = _final_goals(score)
        combined = g1 + g2
        total_goals += combined
        if combined >= 4:
            high_scoring += 1

        margin = abs(g1 - g2)
        if margin > biggest["margin"]:
            hi, lo = (m["team1"], m["team2"]) if g1 >= g2 else (m["team2"], m["team1"])
            biggest = {"label": f"{hi} {max(g1, g2)}–{min(g1, g2)} {lo}", "margin": margin}
        if combined > highest["goals"]:
            highest = {"label": f"{m['team1']} {g1}–{g2} {m['team2']}", "goals": combined}

        for side, team, opp in (
            ("goals1", m.get("team1"), m.get("team2")),
            ("goals2", m.get("team2"), m.get("team1")),
        ):
            per_match: Counter[str] = Counter()
            for goal in m.get(side) or []:
                if not isinstance(goal, dict) or goal.get("owngoal"):
                    continue
                name = goal.get("name")
                if not name:
                    continue
                scorer_goals[name] += 1
                per_match[name] += 1
            for name, n in per_match.items():
                if n >= 3:
                    hat_tricks.append({"name": name, "team": team, "opponent": opp, "goals": n})

    top = scorer_goals.most_common(10)
    top_scorers = [{"name": n, "goals": g} for n, g in top]
    golden_boot = top_scorers[0] if top_scorers else {"name": None, "goals": 0}

    knockout = []
    for m in sorted(
        (m for m in matches if not _is_group(m) and _is_played(m)),
        key=lambda m: (KO_ORDER.index(m["round"]) if m.get("round") in KO_ORDER else 99, m.get("num") or 0),
    ):
        score = m.get("score") or {}
        g1, g2 = _final_goals(score)
        extra = ""
        if isinstance(score.get("p"), list):
            extra = f"pen. {score['p'][0]}–{score['p'][1]}"
        elif isinstance(score.get("et"), list):
            extra = "a.e.t."
        knockout.append({
            "round": m["round"],
            "team1": m["team1"],
            "team2": m["team2"],
            "result": f"{g1}–{g2}",
            "extra": extra,
            "winner": _winner(m),
            "date": m.get("date"),
            "ground": m.get("ground"),
        })

    return {
        "name": "World Cup 2026",
        "champion": champion,
        "runner_up": runner_up,
        "third_place": third_place,
        "final": (
            {
                "team1": final_m["team1"],
                "team2": final_m["team2"],
                "result": "–".join(str(x) for x in _final_goals(final_m.get("score") or {})),
                "ground": final_m.get("ground"),
                "date": final_m.get("date"),
            }
            if final_m
            else None
        ),
        "matches_played": played,
        "total_goals": total_goals,
        "goals_per_match": round(total_goals / played, 2) if played else 0.0,
        "high_scoring_matches": high_scoring,
        "biggest_win": biggest if biggest["margin"] >= 0 else {"label": None, "margin": 0},
        "highest_scoring": highest if highest["goals"] >= 0 else {"label": None, "goals": 0},
        "hat_tricks": len(hat_tricks),
        "hat_trick_list": hat_tricks,
        "penalty_shootouts": penalty_shootouts,
        "extra_time_matches": extra_time,
        "golden_boot": golden_boot,
        "top_scorers": top_scorers,
        "knockout": knockout,
        "source": "openfootball/worldcup.json",
    }


def _publish_metrics(recap: dict[str, Any]) -> None:
    TOTAL_GOALS.set(recap["total_goals"])
    MATCHES_PLAYED.set(recap["matches_played"])
    AVG_GOALS_PER_MATCH.set(recap["goals_per_match"])
    HIGH_SCORING_MATCHES.set(recap["high_scoring_matches"])
    MAX_WIN_MARGIN.set(recap["biggest_win"]["margin"])
    HAT_TRICKS.set(recap["hat_tricks"])
    PENALTY_SHOOTOUTS.set(recap["penalty_shootouts"])
    EXTRA_TIME_MATCHES.set(recap["extra_time_matches"])
    GOLDEN_BOOT_GOALS.set(recap["golden_boot"]["goals"])
    if recap["champion"]:
        CHAMPION.labels(team=recap["champion"]).set(1)


async def _refresh_once(client: httpx.AsyncClient) -> bool:
    REFRESH_ATTEMPTS.inc()
    started_at = time.monotonic()
    try:
        res = await client.get(UPSTREAM_URL)
        res.raise_for_status()
        payload = res.json()
        matches = payload.get("matches") if isinstance(payload, dict) else None
        if not isinstance(matches, list) or not matches:
            raise ValueError("upstream payload had no matches array")

        recap = _compute_recap(matches)
        _publish_metrics(recap)
        REFRESH_SUCCESSES.inc()
        refreshed_at = time.time()
        LAST_REFRESH.set(refreshed_at)
        REFRESH_DURATION.observe(time.monotonic() - started_at)

        async with _cache_lock:
            _cache["updated_at"] = refreshed_at
            recap["upstream_errors"] = _cache["errors"]
            recap["last_refresh"] = refreshed_at
            _cache["recap"] = recap
        log.info("recap refreshed: champion=%s matches=%s goals=%s",
                 recap["champion"], recap["matches_played"], recap["total_goals"])
        return True
    except Exception as exc:  # noqa: BLE001 - one bad fetch must never crash the loop
        UPSTREAM_ERRORS.inc()
        REFRESH_DURATION.observe(time.monotonic() - started_at)
        async with _cache_lock:
            _cache["errors"] += 1
            if _cache["recap"]:
                _cache["recap"]["upstream_errors"] = _cache["errors"]
        log.warning("upstream refresh failed: %s", exc)
        return False


async def _refresh_loop() -> None:
    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT, headers={"User-Agent": "world-cup-2026-monitor"}) as client:
        while True:
            ok = await _refresh_once(client)
            await asyncio.sleep(REFRESH_SECONDS if ok else RETRY_SECONDS)


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(_refresh_loop())
    try:
        yield
    finally:
        task.cancel()


app = FastAPI(title="World Cup 2026 Monitor", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

# The page is a self-contained dark dashboard plus a Google-fonts link;
# lock the browser down to exactly that.
_SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'self'; "
        "style-src 'self' https://fonts.googleapis.com; "
        "font-src https://fonts.gstatic.com; "
        "img-src 'self' data:; "
        "connect-src 'self'; "
        "frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Permissions-Policy": "geolocation=(), camera=(), microphone=(), interest-cohort=()",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
}


@app.middleware("http")
async def security_headers(request, call_next):
    response = await call_next(request)
    for name, value in _SECURITY_HEADERS.items():
        response.headers.setdefault(name, value)
    return response


@app.get("/healthz")
async def healthz() -> dict:
    return {"status": "ok"}


@app.get("/api/tournament")
async def api_tournament() -> JSONResponse:
    async with _cache_lock:
        return JSONResponse(
            {
                "recap": _cache["recap"],
                "updated_at": _cache["updated_at"],
                "upstream_errors": _cache["errors"],
            }
        )


@app.get("/metrics")
async def metrics() -> PlainTextResponse:
    # Only the derived, request-time value is set here. The recap gauges
    # are owned exclusively by _refresh_once().
    async with _cache_lock:
        updated_at = _cache["updated_at"]
    CACHE_AGE.set(max(0.0, time.time() - updated_at) if updated_at else 0.0)
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


# Static frontend last, so /api and /metrics above take precedence.
app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")
