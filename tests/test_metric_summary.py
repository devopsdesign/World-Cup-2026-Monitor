import pytest

from src.app.main import _compute_summary


def test_summary_metrics_are_meaningful_for_completed_tournament():
    live_data = []
    all_matches = [
        {
            "status": "completed",
            "home_team": {"goals": 2},
            "away_team": {"goals": 1},
        },
        {
            "status": "completed",
            "home_team": {"goals": 3},
            "away_team": {"goals": 3},
        },
        {
            "status": "in_progress",
            "home_team": {"goals": 1},
            "away_team": {"goals": 0},
        },
    ]

    summary = _compute_summary(live_data, all_matches)

    assert summary["total_matches"] == 3
    assert summary["completed_matches"] == 2
    assert summary["total_goals"] == 10
    assert summary["average_goals_per_match"] == pytest.approx(3.3333333333333335)
    assert summary["high_scoring_matches"] == 1
