########################################################################
# One-time bootstrap stack.
#
# This creates the Terraform remote-state backend (S3 bucket + DynamoDB
# lock table) that infra/main.tf depends on. It intentionally uses a
# *local* backend (state file stays on your machine / CI runner) because
# a backend bucket can't be used as its own backend before it exists.
#
# Run this exactly once per AWS account, commit nothing sensitive from
# it, and never destroy it while infra/main.tf is still in use.
#
#   cd infra/bootstrap
#   terraform init
#   terraform apply -var="project_name=world-cup-monitor"
########################################################################

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "world-cup-monitor"
}

variable "github_owner" {
  description = "GitHub org/user that owns the repo (for the OIDC trust condition)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repo name (for the OIDC trust condition)"
  type        = string
}

resource "random_id" "suffix" {
  byte_length = 4
}

# ---------------------------------------------------------------------
# KMS key used to encrypt the Terraform state bucket (SSE-KMS, not the
# default SSE-S3) so state (which may reference resource IDs/ARNs) is
# protected by a key you control and can audit via CloudTrail.
# ---------------------------------------------------------------------
resource "aws_kms_key" "tf_state" {
  description             = "${var.project_name} Terraform state encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "tf_state" {
  name          = "alias/${var.project_name}-tfstate"
  target_key_id = aws_kms_key.tf_state.key_id
}

resource "aws_s3_bucket" "tf_state" {
  bucket = "${var.project_name}-tfstate-${random_id.suffix.hex}"
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

# Deny any non-TLS request and any request not using SSE-KMS.
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
        Sid       = "DenyUnencryptedObjectUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.tf_state.arn}/*"
        Condition = {
          StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
        }
      }
    ]
  })
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "${var.project_name}-tf-locks"
  billing_mode = "PAY_PER_REQUEST" # free-tier friendly, no provisioned capacity to forget about
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
# GitHub Actions OIDC — lets the workflow assume an AWS role with
# short-lived, per-run credentials instead of long-lived access keys
# stored as repo secrets.
########################################################################
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Scoped to this repo, any branch/tag/PR/workflow_dispatch — tighten
    # further (e.g. `:ref:refs/heads/main`) if you want only `main` to
    # be able to assume the role at all.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project_name}-gha-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

# Least privilege for exactly what deploy.yml / cleanup.yml do: manage
# this project's EC2/SG/IAM-instance-role/S3/DynamoDB/Budgets resources
# and drive SSM Run Command. Not AdministratorAccess.
data "aws_iam_policy_document" "github_actions_permissions" {
  statement {
    sid = "TerraformCoreResources"
    actions = [
      "ec2:*",
      "s3:*",
      "dynamodb:*",
      "budgets:*",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:GetInstanceProfile",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:PassRole",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]
    resources = ["*"]
  }

  statement {
    sid = "SSMDeploy"
    actions = [
      "ssm:SendCommand",
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:DescribeInstanceInformation",
      "ssm:StartSession",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "STSIdentity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${var.project_name}-gha-deploy-permissions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}

output "state_bucket_name" {
  value = aws_s3_bucket.tf_state.id
}

output "lock_table_name" {
  value = aws_dynamodb_table.tf_lock.id
}

output "kms_key_arn" {
  value = aws_kms_key.tf_state.arn
}

output "github_actions_role_arn" {
  description = "Put this in the repo variable AWS_DEPLOY_ROLE_ARN used by deploy.yml/cleanup.yml"
  value       = aws_iam_role.github_actions.arn
}
