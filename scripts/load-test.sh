#!/bin/bash
# Run this locally to simulate traffic and trigger auto-scaling

echo "🚀 Starting Load Test for E-Commerce Simulator..."
echo "This will send requests to the app and trigger CPU spikes."
echo "Watch your HPA and Grafana dashboard in real-time!"

# Get the public IP (replace with your EC2 IP if running locally)
# If running inside the cluster, use: kubectl get svc -n world-cup-monitoring world-cup-app-service
APP_IP="100.54.23.83"
IP="34.231.241.91"
APP_PORT="30080" # Or the NodePort of your app service

echo "Target: http://$APP_IP:$APP_PORT"

# Generate load for 2 minutes
for i in {1..120}; do
  # Send 50 concurrent requests per second for 1 second
  for j in {1..50}; do
    curl -s "http://$APP_IP:$APP_PORT" > /dev/null &
  done
  wait
  
  echo "⚡ Load sent ($i/120). Check Grafana: http://$APP_IP:30030"
  sleep 1
done

echo "✅ Load test complete. Check if HPA scaled up pods!"
kubectl get hpa -n world-cup-monitoring
kubectl get pods -n world-cup-monitoring