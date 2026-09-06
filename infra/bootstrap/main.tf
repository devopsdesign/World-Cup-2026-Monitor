########################################################################
# One-time bootstrap stack — run locally, once per AWS account, with
# administrator credentials.
#
# Creates everything infra/main.tf's remote backend and CI pipeline
# depend on:
#   * KMS CMK + S3 bucket for Terraform state (SSE-KMS, versioned,
#     public access blocked, TLS-only + KMS-only bucket policy)
#   * DynamoDB table for state locking (PAY_PER_REQUEST)
#   * GitHub Actions OIDC provider
#   * an IAM role GitHub Actions assumes via OIDC, scoped to this repo,
#     with least-privilege permissions (no static access keys anywhere)
#
# This stack uses a LOCAL backend on purpose: the state bucket cannot
# be its own backend before it exists. Keep terraform.tfstate for this
# directory somewhere safe (it is gitignored) or migrate it into the
# bucket afterwards if you prefer.
#
#   cd infra/bootstrap
#   terraform init
#   terraform apply \
#     -var="github_owner=<your-org-or-user>" \
#     -var="github_repo=World-Cup-2026-Monitor"
########################################################################

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region the whole project is deployed into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix for every resource this project creates"
  type        = string
  default     = "world-cup-monitor"
}

variable "github_owner" {
  description = "GitHub org/user that owns the repo (OIDC trust condition)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (OIDC trust condition)"
  type        = string
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # Deterministic + globally unique (account IDs are unique), so the
  # name is predictable and re-running bootstrap is idempotent.
  state_bucket_name = "${var.project_name}-tfstate-${local.account_id}"
}

########################################################################
# KMS CMK for the state bucket — a customer-managed key you can audit
# in CloudTrail and rotate, rather than the default SSE-S3 keys.
########################################################################
resource "aws_kms_key" "tf_state" {
  description             = "${var.project_name} Terraform state encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "tf_state" {
  name          = "alias/${var.project_name}-tfstate"
  target_key_id = aws_kms_key.tf_state.key_id
}

########################################################################
# Terraform state bucket
########################################################################
resource "aws_s3_bucket" "tf_state" {
  bucket = local.state_bucket_name
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tf_state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# TLS-only + KMS-only. Any plain-HTTP request or any upload that isn't
# SSE-KMS is denied outright, regardless of IAM.
resource "aws_s3_bucket_policy" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tf_state.arn,
          "${aws_s3_bucket.tf_state.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid       = "DenyNonKmsUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.tf_state.arn}/*"
        Condition = {
          StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
        }
      },
    ]
  })
}

########################################################################
# State locking
########################################################################
resource "aws_dynamodb_table" "tf_lock" {
  name         = "${var.project_name}-tf-locks"
  billing_mode = "PAY_PER_REQUEST" # no provisioned capacity => Free-Tier safe
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

########################################################################
# GitHub Actions OIDC federation
########################################################################
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC certificate thumbprints. Since mid-2023 AWS STS no
  # longer actually verifies this value for IdPs whose certificate
  # chains to a trusted root CA (GitHub's does), but the API still
  # requires at least one entry. Both currently-published values are
  # listed for resilience across GitHub's cert rotations.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only tokens minted for THIS repo (any branch/tag/PR/environment).
    # Tighten to e.g. "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main"
    # if only main should ever be able to assume the role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "${var.project_name}-gha-deploy"
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
}

########################################################################
# Least-privilege permissions for the CI role — exactly what
# deploy.yml / cleanup.yml need, scoped to this project's resources.
########################################################################
data "aws_iam_policy_document" "github_actions_permissions" {

  # --- Remote state: bucket, objects, lock table, and the CMK ---
  statement {
    sid     = "ProjectStateBuckets"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::${local.state_bucket_name}",
      "arn:aws:s3:::${local.state_bucket_name}/*",
      "arn:aws:s3:::${var.project_name}-manifests-*",
      "arn:aws:s3:::${var.project_name}-manifests-*/*",
    ]
  }

  statement {
    sid     = "ProjectStateLockTable"
    effect  = "Allow"
    actions = ["dynamodb:*"]
    resources = [
      aws_dynamodb_table.tf_lock.arn,
      "${aws_dynamodb_table.tf_lock.arn}/*",
    ]
  }

  statement {
    sid    = "StateEncryptionKey"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
    ]
    resources = [aws_kms_key.tf_state.arn]
  }

  # --- Compute: EC2 + everything the K3s host stack touches, pinned
  #     to the project's region ---
  statement {
    sid       = "Ec2InProjectRegion"
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # --- IAM: only this project's node role + instance profile ---
  statement {
    sid    = "ProjectInstanceRoleAndProfile"
    effect = "Allow"
    actions = [
      "iam:GetRole", "iam:CreateRole", "iam:DeleteRole",
      "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
      "iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:ListInstanceProfilesForRole", "iam:ListInstanceProfileTags",
      "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${var.project_name}-*",
      "arn:aws:iam::${local.account_id}:instance-profile/${var.project_name}-*",
    ]
  }

  statement {
    sid       = "PassNodeRoleToEc2Only"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project_name}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # --- Budgets: only this project's Free-Tier guard budget ---
  statement {
    sid       = "ProjectBudget"
    effect    = "Allow"
    actions   = ["budgets:ViewBudget", "budgets:ModifyBudget", "budgets:ListTagsForResource"]
    resources = ["arn:aws:budgets::${local.account_id}:budget/${var.project_name}-*"]
  }

  # --- ECR Public: push this project's public image ---
  statement {
    sid    = "ProjectEcrPublicPush"
    effect = "Allow"
    actions = [
      "ecr-public:GetAuthorizationToken",
      "ecr-public:BatchCheckLayerAvailability",
      "ecr-public:InitiateLayerUpload",
      "ecr-public:UploadLayerPart",
      "ecr-public:CompleteLayerUpload",
      "ecr-public:PutImage",
    ]
    resources = ["*"]
  }

  # --- SSM: read command/instance state (no resource-level support) ---
  statement {
    sid    = "SsmReadState"
    effect = "Allow"
    actions = [
      "ssm:DescribeInstanceInformation",
      "ssm:GetCommandInvocation",
      "ssm:ListCommands",
      "ssm:ListCommandInvocations",
    ]
    resources = ["*"]
  }

  # --- SSM: run the shell document against this project's instances ---
  statement {
    sid       = "SsmSendCommandDocument"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "SsmSendCommandInstances"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringLike"
      variable = "ssm:resourceTag/Name"
      values   = ["${var.project_name}-*"]
    }
  }

  statement {
    sid       = "CallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${var.project_name}-gha-deploy-permissions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}

########################################################################
# Outputs — the values you wire into the repo and infra/main.tf
########################################################################
output "state_bucket_name" {
  description = "S3 bucket for Terraform remote state (repo variable TF_STATE_BUCKET / -backend-config bucket=)"
  value       = aws_s3_bucket.tf_state.id
}

output "lock_table_name" {
  description = "DynamoDB lock table (repo variable TF_LOCK_TABLE / -backend-config dynamodb_table=)"
  value       = aws_dynamodb_table.tf_lock.id
}

output "state_kms_key_arn" {
  description = "CMK ARN for the state bucket"
  value       = aws_kms_key.tf_state.arn
}

output "state_kms_key_alias" {
  description = "CMK alias — used as kms_key_id in infra/main.tf's backend block"
  value       = aws_kms_alias.tf_state.name
}

output "aws_role_arn" {
  description = "Store as the repo variable/secret AWS_ROLE_ARN used by deploy.yml and cleanup.yml"
  value       = aws_iam_role.github_actions.arn
}

output "aws_region" {
  description = "Store as the repo variable AWS_REGION"
  value       = var.aws_region
}
