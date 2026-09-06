#!/bin/bash
set -euo pipefail

# Runs ON THE K3S NODE via SSM Run Command (see .github/workflows/deploy.yml).
# It talks to Grafana over loopback, so Grafana never has to be reachable
# from the GitHub runner / the internet for dashboards to be provisioned.
#
#   GRAFANA_URL             default http://127.0.0.1:30030
#   GRAFANA_ADMIN_USER      default "admin"
#   GRAFANA_ADMIN_PASSWORD  if unset, read from the grafana-admin-credentials
#                           Secret with the node's local kubectl

GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:30030}"
GRAFANA_USER="${GRAFANA_ADMIN_USER:-admin}"

if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  GRAFANA_ADMIN_PASSWORD=$(k3s kubectl -n world-cup-monitoring get secret grafana-admin-credentials \
    -o jsonpath='{.data.admin-password}' | base64 -d)
fi
: "${GRAFANA_ADMIN_PASSWORD:?could not resolve the Grafana admin password}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Node layout: /tmp/k8s/import-dashboards.sh + /tmp/k8s/dashboards/dashboards/*.json
# Repo layout (local runs): scripts/import-dashboards.sh + docs/dashboards/dashboards/*.json
for candidate in "$SCRIPT_DIR/dashboards/dashboards" "$SCRIPT_DIR/../docs/dashboards/dashboards"; do
  if [ -d "$candidate" ]; then DASH_DIR="$candidate"; break; fi
done
: "${DASH_DIR:?could not find a dashboards directory}"

echo "Waiting for Grafana at $GRAFANA_URL ..."
for i in $(seq 1 30); do
  if curl -sf -u "$GRAFANA_USER:$GRAFANA_ADMIN_PASSWORD" "$GRAFANA_URL/api/health" >/dev/null 2>&1; then
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
  local file=$1 name http_code
  name=$(jq -r '.dashboard.title' "$file")
  echo "Importing: $name ..."
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

shopt -s nullglob
found=0
for dashboard in "$DASH_DIR"/*.json; do
  found=1
  import_dashboard "$dashboard"
done
[ "$found" -eq 1 ] || { echo "No dashboard JSON files in $DASH_DIR" >&2; exit 1; }

echo "All dashboards imported."
