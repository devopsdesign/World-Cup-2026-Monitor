# ⚽ World Cup 2026 Monitor

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![AWS](https://img.shields.io/badge/AWS-%23FF9900.svg?logo=amazon-aws&logoColor=white)](https://aws.amazon.com/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-%23326CE5.svg?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?logo=Prometheus&logoColor=white)](https://prometheus.io/)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?logo=Grafana&logoColor=white)](https://grafana.com/)

A cloud-native observability stack for the 2026 FIFA World Cup — a soccer-themed
tournament recap backed by **K3s**, **Prometheus**, **Grafana**, and a small
**Python/FastAPI** service, deployed entirely inside the **AWS Free Tier** with no
SSH keys, no public Kubernetes API, and no long-lived AWS credentials in CI.

📄 **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — system & runtime diagrams, deploy sequence, design decisions
🔒 **[docs/SECURITY.md](docs/SECURITY.md)** — threat model, the full control catalogue (all $0), how to verify each one, break-glass

---

## Architecture

```text
 ┌───────────────────────────┐   ┌───────────────────────────┐
 │ openfootball/worldcup.json │◄──┤  world-cup-web (FastAPI)  │
 │ (static 2026 results JSON) │   │  frontend + /api/tournament│
 └───────────────────────────┘   │  + /metrics                │
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

Single `t3.micro` EC2 instance running K3s. The Kubernetes API listens
on `6443`, but the security group opens **no 6443 ingress rule**, so it
is unreachable from the internet. (It is *not* bound to loopback —
doing so breaks the in-cluster `kubernetes` service and kills CoreDNS.)
All cluster management happens over **AWS SSM Run Command** running
`k3s kubectl` on the node, which needs no inbound port. There is no SSH
key anywhere in this stack; interactive shell access goes through
**SSM Session Manager**.

| Exposed publicly | Port | What |
|---|---|---|
| ✅ | 30080 | `world-cup-web` — soccer-themed tournament recap, `/api/tournament`, `/metrics` |
| ✅ (or restrict via `grafana_nodeport_cidr`) | 30030 | Grafana dashboards |
| ❌ | — | Prometheus (ClusterIP only — reach via an SSM tunnel) |
| ❌ | — | SSH (22) — does not exist |
| ❌ | — | Kubernetes API (6443) — listening, but no SG ingress rule |

---

## Security posture

Free-Tier, ~$0/month, and hardened at every layer — **[docs/SECURITY.md](docs/SECURITY.md)**
has the full catalogue, the threat model, verification commands, and break-glass.
The short version:

- **Network** — security group opens only `30080` (app) and `30030` (Grafana). No `22`, no `6443`.
- **Identity** — CI authenticates with **GitHub OIDC** to a resource-scoped IAM role (≤1 h sessions); no static AWS keys anywhere.
- **Node** — SSM only (Run Command + Session Manager); no SSH daemon, no key pair. Manifests are applied *on the node*, so the runner never touches the K8s API.
- **K3s** — `--secrets-encryption`, metadata audit log, `profiling=false`, `service-account-lookup=true`; Traefik/servicelb/metrics-server disabled.
- **Workloads** — namespace **Pod Security Admission** (`enforce: baseline`, `audit/warn: restricted`); every pod is non-root, no caps, no priv-esc, read-only rootfs, `RuntimeDefault` seccomp, no SA token.
- **NetworkPolicy** — default-deny + explicit allows, **enforced** by K3s's built-in controller.
- **App** — strict CSP + security headers on every response, docs endpoints disabled, third-party data rendered as text only, upstream fetched server-side with bounded timeouts.
- **AWS account** (`infra/bootstrap`) — default EBS encryption, account-wide S3 Block Public Access, IAM Access Analyzer, IAM password policy, KMS-encrypted/versioned/TLS-only state bucket.
- **Cost** — `cpu_credits = "standard"` (no T3-Unlimited surprise), instance-type validation, `$1` Budgets alarm, a `cleanup.yml` that verifies a clean account.

---

## One-time setup (per AWS account)

1. **Bootstrap the backend + OIDC role + account security baseline**
   (local Terraform, run once by a human with AWS admin credentials):
   ```bash
   cd infra/bootstrap
   terraform init
   terraform apply \
     -var="github_owner=<your-github-org-or-user>" \
     -var="github_repo=World-Cup-2026-Monitor"
   #   -var="aws_region=us-east-1"                 # only if not us-east-1
   #   -var="manage_account_password_policy=false" # if you manage it elsewhere
   #   -var="lock_default_security_group=true"     # CIS 5.4, if nothing else uses the default VPC
   #   -var="enable_cloudtrail=true"               # durable API log (~$0.05/mo of S3)

   terraform output          # copy these values into the repo config below
   ```
   Outputs: `state_bucket_name`, `lock_table_name`, `state_kms_key_arn`,
   `state_kms_key_alias`, `aws_role_arn`, `aws_region`, `access_analyzer_arn`.
   This also turns on default EBS encryption, account-wide S3 Block Public
   Access, IAM Access Analyzer, and an IAM password policy — see
   [docs/SECURITY.md](docs/SECURITY.md#controls). Re-run it after pulling
   changes to `infra/bootstrap/`.

2. **Wire up the remote backend** for the main stack:
   ```bash
   cd ../                    # infra/
   cp backend.hcl.example backend.hcl
   # edit backend.hcl: set bucket = <state_bucket_name from step 1>
   ```
   (`infra/backend.hcl` is gitignored — it holds your account ID. CI
   passes the same values via `-backend-config` flags instead.)

3. **Configure the repo** (Settings → Actions):
   - **Variables**: `AWS_REGION`, `AWS_ROLE_ARN` (= `aws_role_arn`
     output), `TF_STATE_BUCKET` (= `state_bucket_name`), `TF_LOCK_TABLE`
     (= `lock_table_name`), `GRAFANA_NODEPORT_CIDR` (`0.0.0.0/0` or your
     IP `/32`), `BUDGET_ALERT_EMAIL`, `MONTHLY_BUDGET_USD` (default `1`),
       (These aren't secret, so repo *Variables* are fine. If you'd rather
       keep `AWS_ROLE_ARN` as a *Secret*, add it as one and change
     `vars.AWS_ROLE_ARN` → `secrets.AWS_ROLE_ARN` in both workflows.)
   - **Environment `production`** (Settings → Environments → New):
       add the secret `GRAFANA_ADMIN_PASSWORD` (a strong, unique password
       — this is the only Grafana admin credential that will ever exist),
       and add **required reviewers**
     so `apply`/`destroy` need a human approval.

   The workflow publishes the app image to ECR Public using the GitHub
   OIDC role. Set `ECR_PUBLIC_ALIAS` to the registry alias returned by
   `aws ecr-public describe-registries`. The repository must be public so
   the K3s node can pull it without registry credentials. No local Docker
   installation is required.

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
src/app/           FastAPI app: soccer-themed frontend + /api/tournament + /metrics
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
