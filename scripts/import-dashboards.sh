#!/bin/bash
set -e

GRAFANA_URL="http://${EC2_IP}:30030"
GRAFANA_USER="admin"
GRAFANA_PASS="admin123"

echo "📡 Connecting to Grafana at $GRAFANA_URL..."

# Wait for Grafana
echo "⏳ Waiting for Grafana..."
for i in {1..30}; do
  if curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/health" > /dev/null 2>&1; then
    echo "✅ Grafana is ready!"
    break
  fi
  sleep 5
done

import_dashboard() {
  local file=$1
  local name=$(jq -r '.dashboard.title' "$file")
  
  echo "📤 Importing: $name..."
  
  # Send the full payload including 'overwrite': true
  curl -s -X POST "$GRAFANA_URL/api/dashboards/db" \
    -u "$GRAFANA_USER:$GRAFANA_PASS" \
    -H "Content-Type: application/json" \
    -d @"$file"
  
  if [ $? -eq 0 ]; then
    echo "✅ $name imported/updated successfully!"
  else
    echo "❌ Failed to import $name"
    exit 1
  fi
}

# Loop through JSON files
for dashboard in ./docs/dashboards/dashboards/*.json; do
  if [ -f "$dashboard" ]; then
    import_dashboard "$dashboard"
  fi
done

echo "🎉 All dashboards ready!"