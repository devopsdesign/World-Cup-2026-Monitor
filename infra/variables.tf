variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 Instance Type (must stay Free-Tier eligible: t2.micro / t3.micro)"
  type        = string
  default     = "t3.micro"

  validation {
    condition     = contains(["t2.micro", "t3.micro"], var.instance_type)
    error_message = "instance_type must be t2.micro or t3.micro to stay inside AWS Free Tier."
  }
}

variable "project_name" {
  description = "Project name for tagging"
  type        = string
  default     = "world-cup-monitor"
}

variable "tf_state_bucket" {
  description = "Name of the S3 bucket created by infra/bootstrap (backend config)"
  type        = string
}

variable "tf_lock_table" {
  description = "Name of the DynamoDB lock table created by infra/bootstrap"
  type        = string
}

variable "grafana_nodeport_cidr" {
  description = "CIDR allowed to reach the Grafana NodePort (30030). Defaults to open, but you should restrict this to your own IP/32 if you don't need Grafana to be public."
  type        = string
  default     = "0.0.0.0/0"
}

variable "budget_alert_email" {
  description = "Email address to notify when the AWS Budgets threshold is approached/exceeded"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly budget threshold (USD) used for the Free-Tier cost-safety alarm"
  type        = number
  default     = 1
}
