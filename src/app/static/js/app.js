const REFRESH_MS = 15000;

const el = {
  status: document.getElementById("connStatus"),
  statusText: document.getElementById("connStatusText"),
  grid: document.getElementById("matchGrid"),
  empty: document.getElementById("emptyState"),
};

function setStatus(ok, text) {
  el.status.classList.remove("ok", "err");
  el.status.classList.add(ok ? "ok" : "err");
  el.statusText.textContent = text;
}

function safeText(value, fallback = "—") {
  if (value === null || value === undefined || value === "") return fallback;
  return String(value);
}

function setTile(id, value, digits = 0) {
  const node = document.getElementById(id);
  if (!node) return;
  if (value === null || value === undefined || Number.isNaN(Number(value))) {
    node.textContent = "—";
    return;
  }
  node.textContent = Number(value).toFixed(digits);
}

// All 10 tiles are driven by one JSON payload from /api/live (the
// `stats` object the backend computes once per refresh). The browser
// no longer parses the Prometheus text format.
function applyStats(stats) {
  if (!stats || typeof stats !== "object") return;
  setTile("statLive", stats.live_matches);
  setTile("statGoals", stats.total_goals);
  setTile("statMatches", stats.total_matches);
  setTile("statCompleted", stats.completed_matches);
  setTile("statAvgGoals", stats.average_goals_per_match, 1);
  setTile("statHighScoring", stats.high_scoring_matches);
  setTile("statMargin", stats.largest_margin_of_victory);
  setTile("statIntensity", stats.match_intensity);
  setTile("statErrors", stats.upstream_errors);
  document.getElementById("statUpdated").textContent = stats.last_refresh
    ? new Date(stats.last_refresh * 1000).toLocaleTimeString()
    : "—";
}

// Build DOM nodes with textContent only — match data comes from a
// third-party API and must never be interpreted as HTML.
function renderTeam(team) {
  const wrap = document.createElement("div");
  wrap.className = "team";

  const flag = document.createElement("div");
  flag.className = "team-flag";
  flag.textContent = "⚽";
  wrap.appendChild(flag);

  const name = document.createElement("div");
  name.className = "team-name";
  name.textContent = safeText(team && team.country, "TBD");
  wrap.appendChild(name);

  return wrap;
}

function renderMatchCard(match) {
  const card = document.createElement("article");
  card.className = "match-card";

  const badge = document.createElement("div");
  badge.className = "live-badge";
  const pulse = document.createElement("span");
  pulse.className = "pulse";
  badge.appendChild(pulse);
  badge.appendChild(document.createTextNode("LIVE"));
  card.appendChild(badge);

  const scoreboard = document.createElement("div");
  scoreboard.className = "scoreboard";

  const home = match.home_team || {};
  const away = match.away_team || {};

  scoreboard.appendChild(renderTeam(home));

  const scoreBox = document.createElement("div");
  scoreBox.className = "score-box";
  scoreBox.textContent = `${safeText(home.goals, 0)} : ${safeText(away.goals, 0)}`;
  scoreboard.appendChild(scoreBox);

  scoreboard.appendChild(renderTeam(away));
  card.appendChild(scoreboard);

  const meta = document.createElement("div");
  meta.className = "match-meta";

  const stadium = document.createElement("span");
  stadium.textContent = safeText(match.stadium && match.stadium.name, "Stadium TBD");
  meta.appendChild(stadium);

  const status = document.createElement("span");
  status.textContent = safeText(match.status, "in progress").replace(/_/g, " ");
  meta.appendChild(status);

  card.appendChild(meta);
  return card;
}

async function refresh() {
  try {
    const res = await fetch("/api/live", { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();

    applyStats(data.stats);

    const matches = Array.isArray(data.matches) ? data.matches : [];
    el.grid.innerHTML = "";
    if (matches.length === 0) {
      el.grid.appendChild(el.empty);
    } else {
      matches.forEach((m) => el.grid.appendChild(renderMatchCard(m)));
    }

    const errors = data.stats && data.stats.upstream_errors;
    setStatus(true, errors > 0 ? "degraded upstream" : "live");
  } catch (err) {
    setStatus(false, "connection lost");
  }
}

refresh();
setInterval(refresh, REFRESH_MS);
