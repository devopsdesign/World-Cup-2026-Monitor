const REFRESH_MS = 15000;

const el = {
  status: document.getElementById("connStatus"),
  statusText: document.getElementById("connStatusText"),
  statLive: document.getElementById("statLive"),
  statUpdated: document.getElementById("statUpdated"),
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

// Build DOM nodes with textContent only — match data comes from a
// third-party API and must never be interpreted as HTML.
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

async function refresh() {
  try {
    const res = await fetch("/api/live", { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();

    const matches = Array.isArray(data.matches) ? data.matches : [];
    el.statLive.textContent = matches.length;
    el.statUpdated.textContent = data.updated_at
      ? new Date(data.updated_at * 1000).toLocaleTimeString()
      : "—";

    el.grid.innerHTML = "";
    if (matches.length === 0) {
      el.grid.appendChild(el.empty);
    } else {
      matches.forEach((m) => el.grid.appendChild(renderMatchCard(m)));
    }

    setStatus(true, data.upstream_errors > 0 ? "degraded upstream" : "live");
  } catch (err) {
    setStatus(false, "connection lost");
  }
}

async function refreshTotals() {
  // /metrics is the Prometheus exposition format; parse just the two
  // gauges we care about for the header stat card without adding a
  // second JSON endpoint.
  try {
    const res = await fetch("/metrics", { cache: "no-store" });
    if (!res.ok) return;
    const text = await res.text();
    const match = text.match(/^wc_total_goals_count\s+([\d.]+)/m);
    if (match) {
      document.getElementById("statGoals").textContent = Math.round(parseFloat(match[1]));
    }
  } catch (_) {
    /* non-critical */
  }
}

refresh();
refreshTotals();
setInterval(refresh, REFRESH_MS);
setInterval(refreshTotals, REFRESH_MS);
