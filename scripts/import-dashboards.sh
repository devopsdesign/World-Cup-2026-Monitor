#!/bin/bash
set -euo pipefail

# Requires GRAFANA_URL and GRAFANA_ADMIN_PASSWORD in the environment
# (no hardcoded credentials). GRAFANA_ADMIN_USER defaults to "admin".
: "${GRAFANA_URL:?GRAFANA_URL must be set, e.g. http://<ip>:30030}"
: "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD must be set}"
GRAFANA_USER="${GRAFANA_ADMIN_USER:-admin}"

echo "Connecting to Grafana at $GRAFANA_URL..."

for i in $(seq 1 30); do
  if curl -sf -u "$GRAFANA_USER:$GRAFANA_ADMIN_PASSWORD" "$GRAFANA_URL/api/health" > /dev/null 2>&1; then
    echo "Grafana is ready."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "Grafana never became ready." >&2
    exit 1
  fi
  sleep 5
done

import_dashboard() {
  local file=$1
  local name
  name=$(jq -r '.dashboard.title' "$file")

  echo "Importing: $name..."
  local http_code
  http_code=$(curl -s -o /tmp/grafana-import-response.json -w '%{http_code}' \
    -X POST "$GRAFANA_URL/api/dashboards/db" \
    -u "$GRAFANA_USER:$GRAFANA_ADMIN_PASSWORD" \
    -H "Content-Type: application/json" \
    -d @"$file")

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "$name imported/updated successfully."
  else
    echo "Failed to import $name (HTTP $http_code):" >&2
    cat /tmp/grafana-import-response.json >&2
    exit 1
  fi
}

for dashboard in ./docs/dashboards/dashboards/*.json; do
  if [ -f "$dashboard" ]; then
    import_dashboard "$dashboard"
  fi
done

echo "All dashboards imported."
