########################################################################
# Account-level security baseline — applied by the human who runs the
# bootstrap stack (admin creds), NOT by the CI role. Every control here
# is free: no GuardDuty / Security Hub / Config (all metered).
#
#   terraform -chdir=infra/bootstrap apply
########################################################################

variable "manage_account_password_policy" {
  description = "Manage the IAM account password policy (CIS 1.5–1.11). Free."
  type        = bool
  default     = true
}

variable "lock_default_security_group" {
  description = "Strip all rules from the default VPC security group (CIS 5.4). Leave false if other workloads in the default VPC rely on it."
  type        = bool
  default     = false
}

variable "enable_cloudtrail" {
  description = "Create a management-events CloudTrail to S3. Event history (console, 90 days) is free; this adds durable logging for ~$0–0.05/mo of S3."
  type        = bool
  default     = false
}

# --- EBS: encrypt every new volume by default (CIS 2.2.1) --------------
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# --- S3: block public access for the whole account (CIS 2.1.5) --------
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- IAM Access Analyzer: flag any resource shared outside the account
#     (CIS 1.20). Free. -------------------------------------------------
resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "${var.project_name}-account"
  type          = "ACCOUNT"
}

# --- IAM account password policy (CIS 1.5–1.11) ----------------------
resource "aws_iam_account_password_policy" "this" {
  count = var.manage_account_password_policy ? 1 : 0

  minimum_password_length        = 14
  require_uppercase_characters   = true
  require_lowercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 90
  password_reuse_prevention      = 24
}

# --- Default VPC SG: no rules (CIS 5.4). Opt-in. ---------------------
resource "aws_default_security_group" "default" {
  count  = var.lock_default_security_group ? 1 : 0
  vpc_id = data.aws_vpc.default_for_sg[0].id
  # no ingress, no egress blocks => all traffic denied
}

data "aws_vpc" "default_for_sg" {
  count   = var.lock_default_security_group ? 1 : 0
  default = true
}

# --- CloudTrail: management events -> encrypted, versioned S3. Opt-in. -
resource "aws_s3_bucket" "cloudtrail" {
  count         = var.enable_cloudtrail ? 1 : 0
  bucket        = "${var.project_name}-cloudtrail-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count                   = var.enable_cloudtrail ? 1 : 0
  bucket                  = aws_s3_bucket.cloudtrail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tf_state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  count = var.enable_cloudtrail ? 1 : 0

  statement {
    sid       = "AWSCloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail[0].arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
  statement {
    sid       = "AWSCloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail[0].arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cloudtrail[0].arn, "${aws_s3_bucket.cloudtrail[0].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  policy = data.aws_iam_policy_document.cloudtrail_bucket[0].json
}

resource "aws_cloudtrail" "main" {
  count = var.enable_cloudtrail ? 1 : 0

  name                          = "${var.project_name}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail[0].id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.tf_state.arn

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

output "access_analyzer_arn" {
  value = aws_accessanalyzer_analyzer.account.arn
}
