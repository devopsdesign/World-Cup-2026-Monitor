########################################################################
# World Cup 2026 Monitor — hardened infrastructure
#
# Access model: there is no SSH key and no public Kubernetes API.
# Ports 22 and 6443 are not opened anywhere in this file. All management
# (bootstrapping kubectl, pushing manifests, debugging) happens over
# AWS Systems Manager (SSM Session Manager / Run Command), which needs
# no inbound port at all — the agent on the instance calls out to AWS.
########################################################################

terraform {
  # Remote state lives in the bucket/table/CMK created by infra/bootstrap.
  # `bucket` embeds your AWS account ID, so it is supplied at init time
  # (partial backend config) rather than hardcoded here:
  #
  #   Local:  terraform init -backend-config=backend.hcl
  #           (copy infra/backend.hcl.example -> infra/backend.hcl first)
  #   CI:     see the `terraform init -backend-config=...` flags in
  #           .github/workflows/deploy.yml
  #
  # Everything that is fixed and non-sensitive is declared inline.
  backend "s3" {
    key            = "k3s-cluster/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "world-cup-monitor-tf-locks"
    encrypt        = true
    kms_key_id     = "alias/world-cup-monitor-tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "target_subnet" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "${var.aws_region}a"
}

resource "random_id" "key_suffix" {
  byte_length = 4
}

########################################################################
# Security group — narrowest set of NodePorts actually served, no SSH,
# no Kubernetes API. Everything else is denied by default.
########################################################################
resource "aws_security_group" "k3s_sg" {
  name        = "${var.project_name}-sg-${random_id.key_suffix.hex}"
  description = "Security group for K3s cluster - public app ports only, no SSH/API"
  vpc_id      = data.aws_vpc.default.id

  # Soccer-themed web app (frontend + API + /metrics on one service)
  ingress {
    description = "World Cup app NodePort"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Grafana dashboards — restrict via var.grafana_nodeport_cidr if you
  # don't need it reachable from anywhere.
  ingress {
    description = "Grafana NodePort"
    from_port   = 30030
    to_port     = 30030
    protocol    = "tcp"
    cidr_blocks = [var.grafana_nodeport_cidr]
  }

  # Prometheus intentionally has NO ingress rule: its Service is
  # ClusterIP-only (see k8s/monitoring/monitoring.yaml). Reach it via
  # `aws ssm start-session ... --document-name AWS-StartPortForwardingSession`
  # if you need ad-hoc PromQL access.

  # Port 22 (SSH) and 6443 (Kubernetes API) are deliberately absent.
  # Use SSM Session Manager for shell access and `k3s kubectl` run
  # locally on the node (via SSM Run Command) for cluster management.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

########################################################################
# IAM: instance role with only what the node needs —
#   - SSM core (Session Manager / Run Command, no inbound ports needed)
#   - read-only access to the manifest staging bucket below
# No SSH keypair is created anywhere in this stack.
########################################################################
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "k3s_node" {
  name               = "${var.project_name}-node-role-${random_id.key_suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.k3s_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "manifest_bucket_read" {
  statement {
    sid       = "ReadManifests"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.manifests.arn, "${aws_s3_bucket.manifests.arn}/*"]
  }
}

resource "aws_iam_role_policy" "manifest_bucket_read" {
  name   = "manifest-bucket-read"
  role   = aws_iam_role.k3s_node.id
  policy = data.aws_iam_policy_document.manifest_bucket_read.json
}

resource "aws_iam_instance_profile" "k3s_node" {
  name = "${var.project_name}-node-profile-${random_id.key_suffix.hex}"
  role = aws_iam_role.k3s_node.name
}

########################################################################
# Manifest staging bucket. CI (via OIDC role) uploads rendered k8s
# manifests here; the node (via SSM Run Command) pulls them down and
# applies them with its *local* k3s kubectl — the Kubernetes API is
# never exposed to the internet. Private, encrypted, short retention.
########################################################################
resource "aws_s3_bucket" "manifests" {
  bucket = "${var.project_name}-manifests-${random_id.key_suffix.hex}"

  # Transient staging bucket (1-day lifecycle, no versioning). Let
  # `terraform destroy` empty and remove it in one step instead of
  # failing with BucketNotEmpty when a deploy left manifests behind.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "manifests" {
  bucket                  = aws_s3_bucket.manifests.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "manifests" {
  bucket = aws_s3_bucket.manifests.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_ownership_controls" "manifests" {
  bucket = aws_s3_bucket.manifests.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "manifests" {
  bucket = aws_s3_bucket.manifests.id
  rule {
    id     = "expire-old-manifests"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
  }
}

resource "aws_s3_bucket_policy" "manifests" {
  bucket = aws_s3_bucket.manifests.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.manifests.arn, "${aws_s3_bucket.manifests.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

########################################################################
# EC2 instance — Free Tier guardrails:
#   - t2.micro/t3.micro only (enforced by variable validation)
#   - credit_specification "standard" caps CPU bursting so a runaway
#     workload throttles instead of silently billing you for T3 Unlimited
#   - no SSH key, no public API port
########################################################################
resource "aws_instance" "k3s_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.target_subnet.id
  vpc_security_group_ids      = [aws_security_group.k3s_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.k3s_node.name
  user_data_replace_on_change = true

  credit_specification {
    cpu_credits = "standard" # never burst-bill; throttle instead
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(<<-SCRIPT
    #!/bin/bash
    set -e

    LOG="/var/log/user-data.log"
    echo "=== K3s Bootstrap Started at $(date) ===" > $LOG

    # 2 GB swap — a 1 GB t3.micro running k3s + Prometheus + Grafana is
    # memory-tight; without headroom the control plane thrashes and
    # CoreDNS / local-path-provisioner get OOM-killed during bootstrap.
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=40

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y awscli jq

    # SSM agent ships pre-installed on Ubuntu 22.04's official AMIs; make
    # sure it's enabled so Session Manager / Run Command work immediately.
    snap start amazon-ssm-agent || systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

    # The Kubernetes API is kept private by the security group (no 6443
    # ingress rule anywhere) — NOT by binding the apiserver to loopback.
    # `--bind-address=127.0.0.1` makes the in-cluster `kubernetes` service
    # (10.43.0.1:443 -> node-ip:6443) unreachable, so CoreDNS's kubernetes
    # plugin never syncs and ALL cluster DNS dies. So: bind normally.
    #
    # --resolv-conf: Ubuntu 22.04 runs systemd-resolved, so /etc/resolv.conf
    # is the 127.0.0.53 stub — unreachable from the CoreDNS pod. Point k3s
    # at the real upstream resolver list instead.
    #
    # Hardening (CIS Kubernetes Benchmark) — only zero-runtime-cost flags
    # here. API audit logging is a documented opt-in (docs/SECURITY.md):
    # its default `blocking` mode fsyncs per request and stalls the
    # apiserver on a swapping t3.micro; enable it (in `batch` mode) once
    # the node has headroom.
    #   --secrets-encryption      encrypt Secrets at rest in etcd
    #   profiling=false           disable pprof on apiserver/cm/scheduler
    #   service-account-lookup    reject tokens of deleted ServiceAccounts
    #   streaming-...idle-timeout close idle exec/attach streams
    K3S_ARGS="server --tls-san=127.0.0.1 --disable=servicelb --disable=traefik --disable=metrics-server --write-kubeconfig-mode 600 --kubelet-arg=fail-swap-on=false --resolv-conf=/run/systemd/resolve/resolv.conf --secrets-encryption --kube-apiserver-arg=profiling=false --kube-apiserver-arg=service-account-lookup=true --kube-controller-manager-arg=profiling=false --kube-scheduler-arg=profiling=false --kubelet-arg=streaming-connection-idle-timeout=5m"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$K3S_ARGS" sh -

    systemctl enable --now k3s

    # Wait for the cluster to actually converge; heal a bootstrap race
    # (flannel subnet.env / CoreDNS OOM) with one restart if it doesn't.
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    for i in $(seq 1 30); do
      if k3s kubectl -n kube-system rollout status deploy/coredns --timeout=20s 2>/dev/null; then
        echo "coredns ready after $((i*20))s" >> $LOG
        break
      fi
      if [ "$i" = 12 ]; then
        echo "coredns not ready at 240s — restarting k3s" >> $LOG
        systemctl restart k3s
      fi
      sleep 20
    done
  SCRIPT
  )

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project_name}-k3s-server" }
}

########################################################################
# Free Tier cost-safety net: alert (does not auto-stop anything, but
# guarantees you find out before a surprise bill).
########################################################################
resource "aws_budgets_budget" "free_tier_guard" {
  name         = "${var.project_name}-free-tier-guard"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

output "ec2_public_ip" {
  description = "Public IP of the K3s server"
  value       = aws_instance.k3s_server.public_ip
}

output "ec2_instance_id" {
  description = "Instance ID — target for `aws ssm` commands"
  value       = aws_instance.k3s_server.id
}

output "manifest_bucket" {
  description = "S3 bucket CI stages rendered manifests into"
  value       = aws_s3_bucket.manifests.id
}

# No SSH key, no kubeconfig, no private key material is ever emitted as
# a Terraform output — by design.
