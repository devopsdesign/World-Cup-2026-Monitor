# ⚽ World Cup 2026 Monitor

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![AWS](https://img.shields.io/badge/AWS-%23FF9900.svg?logo=amazon-aws&logoColor=white)](https://aws.amazon.com/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-%23326CE5.svg?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?logo=Prometheus&logoColor=white)](https://prometheus.io/)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?logo=Grafana&logoColor=white)](https://grafana.com/)

A real-time, cloud-native monitoring platform for the 2026 FIFA World Cup — a soccer-themed live scoreboard backed by **K3s**, **Prometheus**, **Grafana**, and a small **Python/FastAPI** service, deployed entirely inside the **AWS Free Tier** with no SSH keys, no public Kubernetes API, and no long-lived AWS credentials in CI.

---

## Architecture

```text
 ┌──────────────────┐        ┌───────────────────────────┐
 │  worldcupjson.net │◄──────┤  world-cup-web (FastAPI)  │
 └──────────────────┘        │  frontend + /api/live      │
                              │  + /metrics                │
                              └──────────────┬─────────────┘
                                              │ scraped by
                                              ▼
                                     ┌────────────────┐        ┌──────────┐
                                     │  Prometheus    │◄───────┤ Grafana  │
                                     │  (ClusterIP)   │  query │ (NodePort│
                                     └────────────────┘        │  30030)  │
                                              ▲                └──────────┘
                                              │ scraped
                                     ┌────────────────┐
                                     │ node-exporter  │
                                     └────────────────┘
```

Single `t3.micro` EC2 instance running K3s. The Kubernetes API is bound
to `127.0.0.1` only — it is **never** reachable from outside the
instance. All cluster management (applying manifests, checking
rollouts) happens over **AWS SSM Run Command**, which needs no inbound
port. There is no SSH key anywhere in this stack; interactive shell
access, if you ever need it, goes through **SSM Session Manager**.

| Exposed publicly | Port | What |
|---|---|---|
| ✅ | 30080 | `world-cup-web` — soccer-themed scoreboard, `/api/live`, `/metrics` |
| ✅ (or restrict via `grafana_nodeport_cidr`) | 30030 | Grafana dashboards |
| ❌ | — | Prometheus (ClusterIP only — reach via an SSM tunnel) |
| ❌ | — | SSH (22) — does not exist |
| ❌ | — | Kubernetes API (6443) — bound to loopback, no SG rule at all |

---

## Security model (what changed from the original audit)

1. **Network** — Security group only opens 30080/30030. No 22, no 6443,
   no `30000-32767` catch-all. See [infra/main.tf](infra/main.tf).
2. **No SSH key, no kubeconfig, no key material as Terraform output or
   CI artifact.** Node management is 100% SSM (Run Command +
   Session Manager). See the `IAM: instance role` section of
   [infra/main.tf](infra/main.tf).
3. **CI auth is GitHub OIDC → a scoped IAM role** (see
   [infra/bootstrap/main.tf](infra/bootstrap/main.tf)), not static
   `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` secrets.
4. **Grafana has no default credentials.** The admin password is a
   GitHub Actions secret, rendered into a Kubernetes `Secret` at deploy
   time (`kubectl create secret ... --dry-run=client`) and never
   committed. Anonymous access and self-signup are disabled.
5. **Cost safety**: `credit_specification { cpu_credits = "standard" }`
   on the EC2 instance prevents surprise T3-Unlimited billing; an
   `aws_budgets_budget` emails you at 80%/100% of a ~$1 threshold; the
   CPU busy-loop placeholder app and the ad-hoc `load-test.sh` (which
   hit hardcoded public IPs) have been removed.
6. **State bucket hardening** — [infra/bootstrap/main.tf](infra/bootstrap/main.tf)
   creates the Terraform backend bucket with public-access-block,
   SSE-KMS, versioning, and a deny-non-TLS/deny-non-KMS bucket policy.
7. **Workloads** run `runAsNonRoot`, drop all Linux capabilities,
   disable privilege escalation, and use read-only root filesystems
   where the container supports it (see every manifest under
   [k8s/](k8s/)). `NetworkPolicy` objects restrict pod-to-pod traffic
   to what's actually needed (note: K3s's default Flannel CNI doesn't
   *enforce* NetworkPolicy — see the comment in
   [k8s/monitoring/networkpolicy.yaml](k8s/monitoring/networkpolicy.yaml)
   for how to make it real).
8. **Supply chain** — the old `pip install` inside a Kubernetes shell
   command at pod-start has been replaced by a pinned, pre-built image
   ([src/app/Dockerfile](src/app/Dockerfile)) built once in CI and
   deployed by immutable tag (`worldcup-web:<git-sha>`, never `:latest`).
9. **Prometheus** no longer runs `--web.enable-lifecycle` (which exposed
   an unauthenticated reload/quit endpoint) and its Service is
   `ClusterIP`, not `NodePort`.
10. **CI/CD** — least-privilege `permissions:` block, a `concurrency`
    group so applies/destroys can't race, a protected `production`
    GitHub Environment (add required reviewers in repo settings), all
    workflow inputs/secrets passed through `env:` rather than
    interpolated directly into shell strings, and every third-party
    Action pinned to a commit SHA (kept current via
    [.github/dependabot.yml](.github/dependabot.yml)).

---

## One-time setup (per AWS account)

1. **Bootstrap the backend + OIDC role** (local Terraform, run once by
   a human with AWS admin access):
   ```bash
   cd infra/bootstrap
   terraform init
   terraform apply \
     -var="project_name=world-cup-monitor" \
     -var="github_owner=<your-github-org-or-user>" \
     -var="github_repo=World-Cup-2026-Monitor"
   ```
   Note the outputs: `state_bucket_name`, `lock_table_name`,
   `github_actions_role_arn`.

2. **Docker Hub**: create an access token for pushing the app image.

3. **Configure the repo** (Settings → Actions):
   - **Variables**: `AWS_REGION` (e.g. `us-east-1`), `AWS_DEPLOY_ROLE_ARN`
     (from step 1), `TF_STATE_BUCKET`, `TF_LOCK_TABLE`,
     `GRAFANA_NODEPORT_CIDR` (`0.0.0.0/0` or your IP `/32`),
     `BUDGET_ALERT_EMAIL`, `MONTHLY_BUDGET_USD` (default `1`),
     `DOCKERHUB_USERNAME`.
   - **Environment `production`** (Settings → Environments → New):
     add secrets `DOCKERHUB_TOKEN` and `GRAFANA_ADMIN_PASSWORD`
     (a strong, unique password — this is the only Grafana admin
     credential that will ever exist), and add **required reviewers**
     so `apply`/`destroy` need a human approval.

---

## Deploying

Push to `main`, or run **Actions → Deploy K3s + Monitoring Stack
(Hardened) → Run workflow** with `action: apply`. The pipeline:
builds & pushes the app image → `terraform apply` → waits for the SSM
agent → stages rendered manifests to a private S3 bucket → applies them
via `aws ssm send-command` running `k3s kubectl` **locally on the
node** → waits for rollouts → imports Grafana dashboards → writes a
summary to the workflow run.

### 🔗 Where to find your live URL

The workflow does not (and should not) hardcode a public IP — EC2
gives the instance a new one on every `apply`. After a successful run:

1. Open the finished **Deploy** run in the **Actions** tab.
2. Read the **Summary** panel (or the `Read Terraform outputs` step's
   output) for `ec2_public_ip`.
3. Your app is live at:
   ```
   http://<ec2_public_ip>:30080/
   ```
   Grafana: `http://<ec2_public_ip>:30030/` (user `admin`, password =
   your `GRAFANA_ADMIN_PASSWORD` secret).

If you'd rather not open the Actions UI, get it from the CLI once you
have the OIDC role configured locally:
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=world-cup-monitor-k3s-server" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
```

**Ad-hoc kubectl/PromQL access** (optional, no open ports required):
```bash
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9090"],"localPortNumber":["9090"]}'
# then browse http://localhost:9090
```

## Tearing down

**Actions → Cleanup Infrastructure (Bulletproof) → Run workflow**,
type `DELETE_ALL` to confirm. This destroys the EC2 instance, its
security group/volumes, and the manifest-staging S3 bucket. The
Terraform state bucket, lock table, and GitHub OIDC role from
`infra/bootstrap` are account-level and are deliberately **not**
deleted by this workflow — remove them yourself via
`terraform destroy` in `infra/bootstrap` only when decommissioning the
project for good.

---

## Repo layout

```
infra/bootstrap/   one-time backend bucket + GitHub OIDC IAM role
infra/             the K3s host, SG, IAM instance role, budget alarm
k8s/               namespace, monitoring stack, the web app
src/app/           FastAPI app: soccer-themed frontend + /api/live + /metrics
scripts/           Grafana dashboard import
docs/dashboards/   Grafana dashboard JSON
```

---

## Lessons learned

- Resource-constrained tuning: fine-grained memory limits on metric
  stores prevent OOM kills on a 1 vCPU / 1 GiB node.
- SSM Run Command + a private S3 staging bucket is a workable
  zero-open-port substitute for `kubectl` from CI when you can't afford
  a bastion or a VPN.

---

## Contact & Portfolio

Built with 💻 by Henry DevOps
Email: devopsdesign@protonmail.com
GitHub: github.com/devopsdesign
LinkedIn: www.linkedin.com/in/devopsdesign
