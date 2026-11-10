variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

variable "role_codepipeline_name" {
  description = "Name of role-codepipeline, from modules/security — needed here to attach a deferred permission once the two CodeBuild projects' ARNs exist"
  type        = string
}

variable "role_terraform_arn" {
  description = "ARN of role-terraform, from bootstrap/ — the CodeBuild projects' own service role, broad-but-guarded (AdministratorAccess minus IAM-user/root operations) since it needs to plan and apply changes to any part of this infrastructure, including this module's own resources (that's the self-mutating part)"
  type        = string
}

variable "db_master_password_secret_arn" {
  description = "ARN of the self-managed RDS master password secret, from modules/data — the Plan CodeBuild project reads db_master_password directly from here via a Secrets Manager environment variable, not a manually-entered pipeline secret"
  type        = string
}
