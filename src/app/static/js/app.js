const REFRESH_MS = 60000; // the recap is a static dataset; a slow poll is plenty

const el = {
  status: document.getElementById("connStatus"),
  statusText: document.getElementById("connStatusText"),
  heroSub: document.getElementById("heroSub"),
  heroFinal: document.getElementById("heroFinal"),
  scorers: document.getElementById("scorerList"),
  knockout: document.getElementById("knockoutRounds"),
};

const abbr = (name) => (name || "").replace(/[^A-Za-z]/g, "").slice(0, 3).toUpperCase() || "—";

const ROUND_ORDER = [
  "Round of 32",
  "Round of 16",
  "Quarter-final",
  "Semi-final",
  "Match for third place",
  "Final",
];

function setStatus(ok, text) {
  el.status.classList.remove("ok", "err");
  el.status.classList.add(ok ? "ok" : "err");
  el.statusText.textContent = text;
}

function setTile(id, value, digits) {
  const node = document.getElementById(id);
  if (!node) return;
  if (value === null || value === undefined || value === "" || Number.isNaN(value)) {
    node.textContent = "–";
    return;
  }
  node.textContent = typeof value === "number" && digits !== undefined ? value.toFixed(digits) : String(value);
}

function applyRecap(recap) {
  if (!recap || typeof recap !== "object" || !recap.champion) return;

  setTile("statChampion", recap.champion);
  setTile("statRunnerUp", recap.runner_up);
  const gb = recap.golden_boot || {};
  setTile("statGoldenBoot", gb.name ? `${gb.name} · ${gb.goals}` : null);
  setTile("statMatches", recap.matches_played);
  setTile("statGoals", recap.total_goals);
  setTile("statAvg", recap.goals_per_match, 2);
  setTile("statBiggestWin", recap.biggest_win && recap.biggest_win.margin ? recap.biggest_win.label : null);
  setTile("statHighest", recap.highest_scoring ? recap.highest_scoring.goals : null);
  setTile("statHatTricks", recap.hat_tricks);
  setTile("statShootouts", recap.penalty_shootouts);

  if (recap.final && recap.champion) {
    el.heroSub.textContent =
      `${recap.champion} beat ${recap.runner_up} ${recap.final.result} in the final at ` +
      `${recap.final.ground} — ${recap.total_goals} goals across ${recap.matches_played} matches.`;

    if (el.heroFinal) {
      el.heroFinal.replaceChildren();
      const tag = document.createElement("small");
      tag.textContent = "Final";
      const line = document.createTextNode(
        ` ${abbr(recap.final.team1 || recap.champion)} ${recap.final.result} ${abbr(recap.final.team2 || recap.runner_up)}`,
      );
      el.heroFinal.append(tag, line);
      el.heroFinal.hidden = false;
    }
  }

  renderScorers(Array.isArray(recap.top_scorers) ? recap.top_scorers : []);
  renderKnockout(Array.isArray(recap.knockout) ? recap.knockout : []);
}

function renderScorers(scorers) {
  el.scorers.replaceChildren();
  if (!scorers.length) {
    const li = document.createElement("li");
    li.className = "empty-state";
    li.textContent = "No scorer data available.";
    el.scorers.appendChild(li);
    return;
  }
  const max = scorers[0].goals || 1;
  scorers.slice(0, 8).forEach((s, i) => {
    const li = document.createElement("li");
    li.className = "scorer";

    const rank = document.createElement("span");
    rank.className = "scorer-rank";
    rank.textContent = String(i + 1);

    const name = document.createElement("span");
    name.className = "scorer-name";
    name.textContent = s.name || "Unknown";

    const bar = document.createElement("span");
    bar.className = "scorer-bar";
    const fill = document.createElement("span");
    fill.className = "scorer-bar-fill";
    fill.style.width = `${Math.max(6, (s.goals / max) * 100)}%`;
    bar.appendChild(fill);

    const goals = document.createElement("span");
    goals.className = "scorer-goals";
    goals.textContent = s.goals;

    li.append(rank, name, bar, goals);
    el.scorers.appendChild(li);
  });
}

function renderKnockout(rows) {
  el.knockout.replaceChildren();
  if (!rows.length) {
    const p = document.createElement("p");
    p.className = "empty-state";
    p.textContent = "No knockout results available.";
    el.knockout.appendChild(p);
    return;
  }

  const byRound = new Map();
  rows.forEach((r) => {
    if (!byRound.has(r.round)) byRound.set(r.round, []);
    byRound.get(r.round).push(r);
  });

  const rounds = [...byRound.keys()].sort(
    (a, b) => (ROUND_ORDER.indexOf(a) + 1 || 99) - (ROUND_ORDER.indexOf(b) + 1 || 99),
  );

  rounds.forEach((round) => {
    const group = document.createElement("div");
    group.className = "round-group";

    const title = document.createElement("h3");
    title.className = "round-title";
    title.textContent = round;
    group.appendChild(title);

    const grid = document.createElement("div");
    grid.className = "match-grid";
    byRound.get(round).forEach((r) => grid.appendChild(renderKnockoutCard(r)));
    group.appendChild(grid);
    el.knockout.appendChild(group);
  });
}

function renderKnockoutCard(r) {
  const card = document.createElement("article");
  card.className = "match-card ko-card";

  const scoreboard = document.createElement("div");
  scoreboard.className = "scoreboard";
  scoreboard.appendChild(renderTeam(r.team1, r.team1 === r.winner));

  const scoreBox = document.createElement("div");
  scoreBox.className = "score-box";
  scoreBox.textContent = r.result;
  scoreboard.appendChild(scoreBox);

  scoreboard.appendChild(renderTeam(r.team2, r.team2 === r.winner));
  card.appendChild(scoreboard);

  const meta = document.createElement("div");
  meta.className = "match-meta";
  const left = document.createElement("span");
  left.textContent = r.ground || "";
  const right = document.createElement("span");
  right.textContent = r.extra || (r.date || "");
  meta.append(left, right);
  card.appendChild(meta);
  return card;
}

function renderTeam(name, isWinner) {
  const wrap = document.createElement("div");
  wrap.className = "team" + (isWinner ? " team--winner" : "");

  const flag = document.createElement("div");
  flag.className = "team-flag";
  flag.textContent = isWinner ? "🏆" : "⚽";
  wrap.appendChild(flag);

  const label = document.createElement("div");
  label.className = "team-name";
  label.textContent = name || "TBD";
  wrap.appendChild(label);

  return wrap;
}

async function refresh() {
  try {
    const res = await fetch("/api/tournament", { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();

    if (!data.recap || !data.recap.champion) {
      setStatus(false, "waiting for data");
      return;
    }
    applyRecap(data.recap);
    const errs = data.recap.upstream_errors || 0;
    setStatus(true, errs > 0 ? "official results (stale upstream)" : "official results");
  } catch (err) {
    setStatus(false, "connection lost");
  }
}

refresh();
setInterval(refresh, REFRESH_MS);
