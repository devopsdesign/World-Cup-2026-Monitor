import time
import random
from prometheus_client import start_http_server, Gauge

MATCH_GOALS = Gauge('world_cup_match_goals', 'Current live goals in the match', ['match_id', 'team'])
STADIUM_ATTENDANCE = Gauge('world_cup_stadium_attendance', 'Live stadium attendance', ['match_id', 'stadium'])

def fetch_live_world_cup_data():
    MATCH_GOALS.labels(match_id="101", team="Mexico").set(random.randint(0, 3))
    MATCH_GOALS.labels(match_id="101", team="USA").set(random.randint(0, 2))
    STADIUM_ATTENDANCE.labels(match_id="101", stadium="Azteca").set(87500)

if __name__ == '__main__':
    start_http_server(8000)
    print("World Cup Exporter running on port 8000...")
    
    while True:
        fetch_live_world_cup_data()
        time.sleep(15)