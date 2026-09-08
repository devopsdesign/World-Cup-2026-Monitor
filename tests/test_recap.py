"""Unit tests for the tournament-recap computation.

Fixture matches use the openfootball/worldcup.json shape:
  { round, num?, date, team1, team2, score: {ft, ht, et?, p?},
    goals1: [{name, minute, penalty?, owngoal?}], goals2: [...], group? }
"""

from src.app.main import _compute_recap

MATCHES = [
    # Group stage — a hat-trick and a clean 3-0
    {
        "round": "Matchday 1", "date": "2026-06-11", "group": "Group A",
        "team1": "Mexico", "team2": "South Africa",
        "score": {"ft": [3, 0], "ht": [1, 0]},
        "goals1": [
            {"name": "Julián Quiñones", "minute": "9"},
            {"name": "Julián Quiñones", "minute": "41"},
            {"name": "Julián Quiñones", "minute": "70"},
        ],
        "goals2": [],
        "ground": "Mexico City",
    },
    # Group stage — highest-scoring match, another hat-trick, one own goal
    {
        "round": "Matchday 1", "date": "2026-06-11", "group": "Group B",
        "team1": "United States", "team2": "Canada",
        "score": {"ft": [4, 3], "ht": [2, 1]},
        "goals1": [
            {"name": "Christian Pulisic", "minute": "10"},
            {"name": "Christian Pulisic", "minute": "40"},
            {"name": "Christian Pulisic", "minute": "55"},
            {"name": "Ricardo Pepi", "minute": "80"},
        ],
        "goals2": [
            {"name": "Jonathan David", "minute": "20"},
            {"name": "Jonathan David", "minute": "60"},
            {"name": "Tim Ream", "minute": "85", "owngoal": True},
        ],
        "ground": "Seattle",
    },
    # Round of 32 — decided on penalties
    {
        "round": "Round of 32", "num": 74, "date": "2026-06-30",
        "team1": "France", "team2": "Switzerland",
        "score": {"p": [3, 4], "et": [1, 1], "ft": [1, 1], "ht": [0, 1]},
        "goals1": [{"name": "Kylian Mbappé", "minute": "50"}],
        "goals2": [{"name": "Breel Embolo", "minute": "17", "penalty": True}],
        "ground": "Kansas City",
    },
    # Quarter-final — extra time only
    {
        "round": "Quarter-final", "num": 99, "date": "2026-07-10",
        "team1": "Spain", "team2": "Brazil",
        "score": {"et": [1, 2], "ft": [1, 1], "ht": [1, 1]},
        "goals1": [{"name": "Ferran Torres", "minute": "30"}],
        "goals2": [{"name": "Vinícius Júnior", "minute": "88"}, {"name": "Rodrygo", "minute": "105"}],
        "ground": "Miami",
    },
    # Third place
    {
        "round": "Match for third place", "num": 103, "date": "2026-07-18",
        "team1": "Brazil", "team2": "France",
        "score": {"ft": [2, 1], "ht": [1, 0]},
        "goals1": [{"name": "Vinícius Júnior", "minute": "20"}, {"name": "Rodrygo", "minute": "75"}],
        "goals2": [{"name": "Kylian Mbappé", "minute": "88"}],
        "ground": "Miami",
    },
    # Final — extra time
    {
        "round": "Final", "num": 104, "date": "2026-07-19",
        "team1": "Spain", "team2": "Argentina",
        "score": {"et": [1, 0], "ft": [0, 0], "ht": [0, 0]},
        "goals1": [{"name": "Ferran Torres", "minute": "106"}],
        "goals2": [],
        "ground": "New York/New Jersey (East Rutherford)",
    },
]


def test_medal_positions():
    recap = _compute_recap(MATCHES)
    assert recap["champion"] == "Spain"
    assert recap["runner_up"] == "Argentina"
    assert recap["third_place"] == "Brazil"


def test_aggregate_stats():
    recap = _compute_recap(MATCHES)
    # goals: 3 + 7 + 2(et 1-1) + 3(et 1-2) + 3 + 1(et 1-0) = 19, over 6 played
    assert recap["matches_played"] == 6
    assert recap["total_goals"] == 19
    assert recap["goals_per_match"] == 3.17
    assert recap["high_scoring_matches"] == 1  # only USA 4-3 Canada
    assert recap["biggest_win"] == {"label": "Mexico 3–0 South Africa", "margin": 3}
    assert recap["highest_scoring"]["goals"] == 7
    assert recap["highest_scoring"]["label"] == "United States 4–3 Canada"


def test_knockout_specifics():
    recap = _compute_recap(MATCHES)
    assert recap["penalty_shootouts"] == 1
    assert recap["extra_time_matches"] == 3
    assert [k["round"] for k in recap["knockout"]] == [
        "Round of 32", "Quarter-final", "Match for third place", "Final",
    ]
    ro32 = recap["knockout"][0]
    assert ro32["result"] == "1–1"
    assert ro32["extra"] == "pen. 3–4"
    assert ro32["winner"] == "Switzerland"


def test_scorers_and_hat_tricks():
    recap = _compute_recap(MATCHES)
    assert recap["hat_tricks"] == 2  # Quiñones, Pulisic
    assert recap["golden_boot"]["goals"] == 3
    # own goal is not attributed to a scorer
    names = {s["name"] for s in recap["top_scorers"]}
    assert "Tim Ream" not in names
    # penalty goal still counts
    assert {"name": "Breel Embolo", "goals": 1} in recap["top_scorers"]
