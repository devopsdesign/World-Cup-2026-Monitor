# Security

How this project is hardened, why each control is there, and how to verify it.
Everything here is **free** — no GuardDuty, Security Hub, AWS Config, WAF, ALB,
NAT gateway, or KMS beyond the one CMK the state bucket needs. The design target
is "defensible on the AWS Free Tier at ~$0/month".

- [Threat model](#threat-model)
- [Controls](#controls)
- [Out of scope](#out-of-scope-and-why)
- [Verifying the controls](#verifying-the-controls)
- [Incident response / break-glass](#incident-response--break-glass)
- [Hardening backlog](#hardening-backlog-opt-in)

---

## Threat model

### Assets

| Asset | Where | Impact if lost |
|---|---|---|
| AWS account | 920534282171 | Resource abuse / bill, data access |
| Terraform state | S3 `…-tfstate-<acct>` (SSE-KMS, versioned) | Infra takeover if writable; recon if readable |
| CI deploy identity | IAM role `…-gha-deploy` (OIDC, no static keys) | Deploy/destroy infra |
| Grafana admin credential | GitHub Actions **environment** secret → K8s Secret | Dashboard tamper; pivot |
| The K3s node | 1× `t3.micro` EC2, SSM-managed, no SSH | Foothold; the whole cluster |
| Tournament data | Public, read-only (`openfootball/worldcup.json`) | None — it's public |

### Actors

- **Internet, unauthenticated** — can reach only TCP `30080` (the app) and `30030`
  (Grafana login). Everything else is closed at the security group.
- **A compromised GitHub Actions run** — holds a ≤1 h OIDC session for the
  `…-gha-deploy` role, scoped to this project's resources in one region.
- **A malicious PR** — cannot reach AWS: the deploy job is gated on the `production`
  environment and only runs from `main` / manual dispatch.
- **A compromised app pod** — runs non-root, no capabilities, read-only rootfs,
  no service-account token, and can only egress DNS + `:443` per NetworkPolicy.

### Trust boundaries

```
Internet ─┬─▶ SG :30080 ─▶ world-cup-web pod           (public, untrusted input from openfootball)
          └─▶ SG :30030 ─▶ Grafana (login required)
GitHub  ───▶ OIDC ───▶ STS ─▶ IAM role (scoped) ─▶ Terraform + SSM
IAM role ──▶ SSM Run Command ─▶ node (`k3s kubectl` locally) ─▶ API on 127-only path
                                     ▲ 6443 has NO security-group ingress rule
```

---

## Controls

### AWS account (`infra/bootstrap/`, run once by an admin)

| Control | Resource | Standard |
|---|---|---|
| No long-lived CI keys — GitHub OIDC → scoped role | `aws_iam_openid_connect_provider`, `aws_iam_role.github_actions` | CIS 1.x, SLSA |
| CI role is resource-scoped (S3/DynamoDB/KMS to named ARNs; EC2 pinned to one region; IAM to `…-node-*`; `PassRole` only to `ec2.amazonaws.com`) | `aws_iam_role_policy.github_actions` | Least privilege |
| Default EBS encryption on for the region | `aws_ebs_encryption_by_default` | CIS 2.2.1 |
| Account-wide S3 Block Public Access | `aws_s3_account_public_access_block` | CIS 2.1.5 |
| IAM Access Analyzer (account) | `aws_accessanalyzer_analyzer` | CIS 1.20 |
| IAM password policy — 14 char, complexity, 90-day rotation, 24 reuse | `aws_iam_account_password_policy` (`var.manage_account_password_policy`) | CIS 1.5–1.11 |
| State bucket: SSE-KMS (CMK), versioned, public-access-blocked, TLS-only + KMS-only bucket policy | `aws_s3_bucket*.tf_state` | CIS 2.1.x |
| Free-Tier budget alarm at $1 (80% actual, 100% forecast → email) | `aws_budgets_budget.free_tier_guard` (in `infra/`) | Cost guardrail |
| *(opt-in)* CloudTrail management events → encrypted, versioned, 90-day S3 | `var.enable_cloudtrail` | CIS 3.1 |
| *(opt-in)* Strip all rules from the default-VPC security group | `var.lock_default_security_group` | CIS 5.4 |

### Network

| Control | Where |
|---|---|
| Security group opens **only** `30080` (app) and `30030` (Grafana) inbound | `aws_security_group.k3s_sg` |
| **No** `22` (SSH) and **no** `6443` (K8s API) ingress anywhere | same |
| Grafana port can be locked to a single CIDR | `var.grafana_nodeport_cidr` |
| Prometheus is `ClusterIP` only — never a NodePort | `k8s/monitoring/monitoring.yaml` |
| K8s API reachable only from the node itself (via `k3s kubectl`) or an SSM port-forward | design |
| In-namespace `default-deny` + explicit `NetworkPolicy` allows (DNS, app `:443` egress, scrape paths) | `k8s/monitoring/networkpolicy.yaml` |
| IMDSv2 required, hop limit 1 (no SSRF → credentials) | `metadata_options` |

### CI/CD (`.github/workflows/`)

| Control | Where |
|---|---|
| `permissions:` is least-privilege (`contents: read`, `id-token: write` only where needed) | all workflows |
| `concurrency` group shared by deploy + cleanup — they can never race | `deploy.yml`, `cleanup.yml` |
| `apply` / `destroy` gated on the protected `production` environment | job `environment:` |
| Every third-party Action pinned to a commit SHA; kept fresh by Dependabot | `.github/dependabot.yml` |
| Every workflow input / secret passed via `env:` — never interpolated into a `run:` string | all workflows |
| `pytest` runs on PRs (`ci.yml`) and gates `build`/`deploy` (`deploy.yml` `test` job) | — |
| Cleanup never enumerates the account — it discovers names from Terraform state and acts on them by name | `cleanup.yml` |
| Cleanup's `Verify the account is clean` step is the sole pass/fail; fails on any leftover | `cleanup.yml` |
| App image built in CI and deployed **by immutable digest/SHA tag**, never `:latest` | `deploy.yml` |
| Manifests + Grafana secret staged to a private, 1-day-lifecycle, SSE-KMS S3 bucket, then pulled and applied **on the node** via SSM — the K8s API is never exposed to the runner | `deploy.yml` |

### Host / K3s (`infra/main.tf` user-data)

| Control | Flag / step | Standard |
|---|---|---|
| Secrets encrypted at rest in etcd | `--secrets-encryption` | CIS 3.1.1 |
| API audit log (metadata level, read-noise dropped), capped 20 MB | `--kube-apiserver-arg=audit-*` + `/var/lib/rancher/k3s/server/audit.yaml` | CIS 3.2.x |
| pprof disabled on apiserver / controller-manager / scheduler | `--*-arg=profiling=false` | CIS 1.2.x/1.3.x/1.4.x |
| Tokens of deleted ServiceAccounts rejected | `--kube-apiserver-arg=service-account-lookup=true` | CIS 1.2.x |
| Idle exec/attach streams closed | `--kubelet-arg=streaming-connection-idle-timeout=5m` | CIS 4.2.5 |
| kubeconfig mode `600` | `--write-kubeconfig-mode 600` | CIS 4.1.x |
| Bundled Traefik / servicelb / metrics-server disabled (smaller surface) | `--disable=…` | attack surface |
| SSM Agent only — no SSH daemon, no key pair anywhere in the stack | design | CIS 4.x |
| CoreDNS convergence gate + one self-healing `k3s restart` on boot | user-data loop | reliability |

### Workload (`k8s/`)

| Control | Where |
|---|---|
| Namespace Pod Security Admission: `enforce: baseline`, `warn`/`audit: restricted` (every workload already meets `restricted`) | `k8s/namespace.yaml` |
| Every pod: `runAsNonRoot`, `runAsUser` ≥ 472, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true` (writable paths are explicit `emptyDir`s) | all deployments |
| `automountServiceAccountToken: false` everywhere except Prometheus (which needs none either — kept for future service discovery) | all deployments |
| CPU/memory `requests` + `limits` on every container | all deployments |
| `node-exporter` (needs hostNetwork/hostPID) isolated in `kube-system`, not the app namespace | `k8s/monitoring/monitoring.yaml` |
| Prometheus runs **without** `--web.enable-lifecycle` (no unauthenticated `/-/reload`, `/-/quit`) | `k8s/monitoring/monitoring.yaml` |
| Grafana: no anonymous access, no sign-up, viewers can't edit, **no outbound calls** (analytics / update checks / external snapshots / Gravatar all off), CSP + `X-Content-Type-Options` + `SameSite=strict` cookies | `k8s/monitoring/monitoring.yaml` |
| Grafana admin password: a GitHub **environment** secret, rendered into a K8s Secret at deploy time (`kubectl create secret --dry-run=client`), never committed, never printed | `deploy.yml` |
| Retired `prometheus-cluster-role` ClusterRole/Binding pruned on every deploy | `deploy.yml` |

### Application (`src/app/`)

| Control | Where |
|---|---|
| Response headers on every route: strict `Content-Security-Policy`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Permissions-Policy`, `Cross-Origin-*-Policy` | `main.py` middleware |
| FastAPI docs / ReDoc / `openapi.json` disabled | `FastAPI(docs_url=None, …)` |
| Upstream is fetched **server-side** with bounded timeouts; failures are swallowed into the last-good cache and counted (`wc_upstream_errors_total`) — a flaky/hostile upstream can't take the app down | `main.py` |
| Frontend builds DOM with `textContent` only — third-party match data is never interpreted as HTML | `static/js/app.js` |
| Pinned, hash-lockable Python deps; multi-stage image; non-root `USER`; `HEALTHCHECK` | `requirements.txt`, `Dockerfile` |
| Image pinned to an exact patch tag (digest-pin ready — see the Dockerfile comment) | `Dockerfile` |

### Data

- **Terraform state** — SSE-KMS with a customer-managed key, versioned, public-access
  blocked, bucket policy denies non-TLS and non-KMS `PutObject`. No secrets are ever
  written to state as outputs (`k3s_private_key_pem` etc. do not exist).
- **Manifest staging bucket** — private, SSE-KMS, `BucketOwnerEnforced`, TLS-only
  bucket policy, 1-day lifecycle expiry, `force_destroy` so cleanup can't get stuck.
- **K8s Secrets** — encrypted at rest (`--secrets-encryption`); only `grafana-admin-credentials` exists.
- **No PII** anywhere — the only data is public tournament results.

### Cost (a security control here — a surprise bill is the likeliest "incident")

- `credit_specification { cpu_credits = "standard" }` — the `t3.micro` throttles to
  baseline instead of silently billing for T3-Unlimited bursting.
- Instance type validated to `t2.micro` / `t3.micro` only (`variable "instance_type"` validation).
- `aws_budgets_budget` emails at 80% actual and 100% forecast of a $1 threshold.
- DynamoDB lock table is `PAY_PER_REQUEST`; buckets have lifecycle expiry; no NAT / ALB / EIP / extra EBS.
- `cleanup.yml` is bulletproof and verifies a clean account, so "tear it down between demos" is reliable.

---

## Out of scope (and why)

| Not done | Why | Cheapest real option |
|---|---|---|
| TLS on the app / Grafana | An ACM cert needs an ALB or CloudFront (both metered) | CloudFront + ACM (~$0 within free tier for low traffic) or Caddy on the node with a real domain |
| WAF / rate limiting | AWS WAF is per-rule + per-request metered | CloudFront + WAF, or `nginx`/`Caddy` limits on the node |
| GuardDuty / Security Hub / AWS Config | All metered after trial | Enable when the project has a budget |
| Multi-AZ / HA | Single `t3.micro` by definition | Not a Free-Tier goal |
| Private subnets + NAT | NAT gateway is ~$32/mo | VPC endpoints for SSM/S3 (still small hourly cost) |
| Centralised log shipping | CloudWatch Logs ingestion is metered | Ship to the free tier of a third-party, or scrape via Loki on the node |
| CloudTrail always-on | S3 PUTs slightly exceed the free tier (~$0.05/mo) | Flip `var.enable_cloudtrail = true` — it's built, just off by default |

---

## Verifying the controls

```bash
# ── AWS account baseline (needs admin creds) ────────────────────────
aws ec2 get-ebs-encryption-by-default                      # EbsEncryptionByDefault: true
aws s3control get-public-access-block --account-id "$(aws sts get-caller-identity --query Account --output text)"
aws accessanalyzer list-analyzers --query 'analyzers[].{name:name,status:status}'
aws iam get-account-password-policy

# ── Network ────────────────────────────────────────────────────────
aws ec2 describe-security-groups --filters Name=tag:Name,Values='world-cup-monitor-*' \
  --query 'SecurityGroups[].IpPermissions[].{from:FromPort,to:ToPort,cidr:IpRanges[].CidrIp}'
#  → only 30080 and 30030; NO 22, NO 6443
nmap -Pn -p 22,6443,30080,30030 <EC2_IP>                   # 22/6443 filtered

# ── App response headers ───────────────────────────────────────────
curl -sI http://<EC2_IP>:30080/ | grep -iE 'content-security-policy|x-frame|x-content-type|referrer-policy'

# ── Cluster (via SSM Run Command, run k3s kubectl on the node) ──────
aws ssm send-command --instance-ids <ID> --document-name AWS-RunShellScript \
  --parameters 'commands=["k3s kubectl get ns world-cup-monitoring -o jsonpath={.metadata.labels}","k3s secrets-encrypt status","k3s kubectl -n world-cup-monitoring get pods -o jsonpath={.items[*].spec.securityContext}"]'
# expect: pod-security enforce=baseline; "Encryption Status: Enabled"; runAsNonRoot everywhere

# ── CI has no static keys ──────────────────────────────────────────
gh secret list        # no AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in use by workflows
grep -rn "aws-access-key-id\|AWS_SECRET" .github/workflows/    # → nothing
```

---

## Incident response / break-glass

- **Shell on the node** — `aws ssm start-session --target <instance-id>` (needs the
  `session-manager-plugin`). No SSH, no key to steal or rotate.
- **Local `kubectl`** without opening `6443` — SSM port-forward:
  ```bash
  aws ssm start-session --target <id> \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}'
  # then use a kubeconfig pointed at https://127.0.0.1:6443 (copy /etc/rancher/k3s/k3s.yaml via SSM)
  ```
- **Suspected node compromise** — run `cleanup.yml` (it verifies a clean account),
  rotate the `GRAFANA_ADMIN_PASSWORD` environment secret, then redeploy. The node
  holds no long-lived credential — only the instance-profile role (SSM core + read
  on one S3 prefix) and a ≤6 h IMDS token.
- **Suspected CI compromise** — in the AWS console, detach
  `…-gha-deploy-permissions` from the role (or delete the role); OIDC sessions are
  ≤1 h so access lapses quickly. Re-`terraform apply` `infra/bootstrap` to restore.
- **Rotate the K8s secrets-encryption key** — `k3s secrets-encrypt rotate` then
  `k3s secrets-encrypt reencrypt` on the node.
- **Audit trail** — `k3s kubectl` mutations: `/var/lib/rancher/k3s/server/audit.log`
  on the node. AWS API calls: CloudTrail *Event history* in the console (90 days,
  free) or the trail if `var.enable_cloudtrail` is on.

---

## Hardening backlog (opt-in)

Ordered by value-for-effort, all still ~$0 unless noted:

1. **Raise `enforce` to `restricted`** in `k8s/namespace.yaml` — every workload
   already complies; flip one label.
2. **`var.enable_cloudtrail = true`** — durable API logging (~$0.05/mo of S3).
3. **`var.lock_default_security_group = true`** — CIS 5.4, if nothing else uses the default VPC.
4. **Digest-pin the app image** — resolve `python:3.11.9-slim@sha256:…` (see the Dockerfile) and pin the CI-built image by digest in the manifest.
5. **`--require-hashes` Python install** — `pip-compile --generate-hashes` a lockfile.
6. **CloudFront + ACM in front of the app** — real TLS, HTTP→HTTPS, and a place to
   attach AWS WAF later. Low-traffic cost is within the CloudFront free tier.
7. **Restrict `grafana_nodeport_cidr`** to your own `/32` if Grafana doesn't need to be public.
8. **kube-bench** as a one-shot Job to score the node against the CIS Kubernetes Benchmark.
9. **Trivy** image + IaC scan as a CI job (`ci.yml`).
