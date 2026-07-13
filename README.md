# ⚽ World Cup 2026 Monitor

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![AWS](https://img.shields.io/badge/AWS-%23FF9900.svg?logo=amazon-aws&logoColor=white)](https://aws.amazon.com/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-%23326CE5.svg?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?logo=Prometheus&logoColor=white)](https://prometheus.io/)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?logo=Grafana&logoColor=white)](https://grafana.com/)

A real-time, cloud-native monitoring platform for the 2026 FIFA World Cup. Built with **Kubernetes (K3s)**, **Prometheus**, **Grafana**, and a custom **Python metric exporter**, this project serves as an end-to-end demonstration of resilient DevOps practices deployed entirely inside the **AWS Free Tier**.

---

## 🎯 Project Goal

To engineer a highly available, scalable metric collection pipeline capable of tracking rapid World Cup match events, visualizing critical telemetry, and triggering smart alerts—engineered strategically to run flawlessly on zero-budget infrastructure limits.

---

## 🏆 Key Achievements

* **Custom Python Exporter:** Architected a lightweight engine to parse, normalize, and expose match-state metrics cleanly to Prometheus endpoints.
* **Low-Overhead Orchestration:** Deployed a lightweight K3s cluster on EC2 (`t2.micro`/`t3.micro`) optimized to handle production workloads with minimal memory footprints.
* **GitOps & IaC Foundations:** Completely automated base networking, security boundaries, and host machine scheduling via modular **Terraform**.
* **Chaos & Validation Testing:** Developed synthetic traffic injection tools to deliberately pressure-test data processing pipelines and compute boundaries.
* **Automated Janitor Closures:** Integrated GitHub Actions workflow pipelines to self-heal or nuke active AWS resources instantly to avoid out-of-band expenses.

---

## 🏗️ Architecture Overview

```text
 ┌─────────────────┐       ┌─────────────────┐       ┌──────────────────┐
 │  World Cup API  ├──────►│ Python Exporter ├──────►│ Prometheus (K3s) │
 └─────────────────┘       └───────┬─────────┘       └────────┬─────────┘
                                   │                          │
                                   ▼                          ▼
                          ┌─────────────────┐       ┌──────────────────┐
                          │ Load Testing    │       │     Grafana      │
                          │   (Traffic)     │       │   Dashboards     │
                          └─────────────────┘       └────────┬─────────┘
                                                             │
                                                             ▼
                                                    ┌──────────────────┐
                                                    │  Alert Manager   │
                                                    └──────────────────┘

Component Breakdown
Exporter: Python microservice exposing metrics on standard /metrics text endpoints.
Orchestration: K3s distribution hosting the active worker node applications.
Infrastructure as Code: Declarative HCL code prescribing explicit VPC, Subnet, and Security Group boundaries.
Observability Pipeline: Integrated Prometheus storage with custom dashboard layouts for localized observability metrics.

🚀 Getting Started
Prerequisites
Valid AWS account configured with programmatic CLI keys.
Local utilities installed: kubectl, helm, terraform, docker.
Deployment Pipeline
1. Clone the Codebase
Bash
git clone [https://github.com/devopsdesign/World-Cup-2026-Monitor.git](https://github.com/devopsdesign/World-Cup-2026-Monitor.git)
cd World-Cup-2026-Monitor
2. Provision AWS Infrastructure
Bash
cd infra
terraform init
terraform apply -var="project_name=world-cup-monitor" -auto-approve
3. Establish Cluster Access
Bash
# Safely route configuration context fields out of your local storage
scp -i ~/.ssh/your-aws-key.pem ubuntu@<EC2_PUBLIC_IP>:/etc/rancher/k3s/k3s.yaml ~/.kube/config
4. Apply Kubernetes Manifests
Bash
cd ../k8s
kubectl apply -f namespaces.yaml
kubectl apply -f secret-manifests/
kubectl apply -f core/
5. Expose the Data Visualization Layer
Bash
kubectl port-forward svc/grafana -n monitoring 3000:80

🌐 Access the live web engine locally at: http://localhost:3000

📊 Dashboards
An analytical template profile is included inside docs/dashboards/world-cup-monitor.json. Import it into your active Grafana container engine to view live telemetry metrics:
Match Engine Metrics: Live dynamic game scores, event updates, and match timing sequences.
Ingress API Telemetry: Real-time query execution times, target latency arrays, and HTTP failure volumes.
Node Telemetry: Host CPU cycles consumed, active system RAM bounds, and storage usage metrics.

🧪 Load Testing
Validate the performance under heavy traffic loads by running the integrated threat script:
Bash
chmod +x ../scripts/load-test.sh
../scripts/load-test.sh --target=http://localhost:8080 --duration=300

🔒 Security Posture
Isolate Secrets: Private key infrastructure (.pem files) is blocked from project scopes.
Hardened Perimeter: Security controls isolate standard compute spaces from unauthenticated traffic.
Least-Privilege RBAC: Pod service identities run with minimal permissions inside Kubernetes boundaries.

📈 AWS Free Tier Guardrails
Micro-Sized Nodes: Workloads run on t2.micro or t3.micro engines to remain inside the monthly 750-hour allowance.
Volumetric Control: Retention variables restrict metric storage volumes to keep data footprints minimal.
Cost Alarms: CloudWatch tracking structures trigger automated email notifications if expected operational expenses pass $0.00.

🧠 Lessons Learned
Resource Constrained Tuning: Configured fine-grained memory limits on metric stores to prevent low-spec worker nodes from experiencing Out-Of-Memory (OOM) crashing bugs.
Optimized Scrape Intervals: Tuned sampling logic to gather real-time data efficiently without hitting third-party external API query limits.

📬 Contact & Portfolio
Built with 💻 by Henry DevOps
Email: devopsdesign@protonmail.com
GitHub: github.com/devopsdesign
LinkedIn: www.linkedin.com/in/devopsdesign                                                   