variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

variable "parent_domain" {
  description = "Domain of the existing hosted zone the app lives under"
  type        = string
  default     = "example.com"
}

# --------------------------------------------------------------------------
# Shared across multiple modules — kept as independently-consumed variables,
# never wired as real module.x.output references between the "producer" and
# "consumer" side. Several of these exist specifically to avoid a graph
# cycle: e.g. identity constructs messaging's Lambda ARN by string
# interpolation rather than reading module.messaging's real output, because
# messaging already depends on identity (for the Cognito invoke permission).
# A real reference the other way would be identity -> messaging -> identity.
# The same reasoning protects security <-> pipeline/messaging below.
# --------------------------------------------------------------------------

variable "ecr_repo_name" {
  description = "Name of the ECR repository. Created by modules/pipeline; also referenced (as a deterministic ARN) by modules/security and modules/compute."
  type        = string
  default     = "hisaab-api"
}

variable "sqs_queue_name" {
  description = "Name of the SQS notifications queue. Created by modules/messaging; also referenced by modules/security."
  type        = string
  default     = "hisaab-notifications"
}

variable "codebuild_project_name" {
  description = "Name of the CodeBuild project. Created by modules/pipeline; also referenced by modules/security."
  type        = string
  default     = "hisaab-api-build"
}

variable "codedeploy_app_name" {
  description = "Name of the CodeDeploy application. Created by modules/pipeline; also referenced by modules/security."
  type        = string
  default     = "hisaab-api"
}

variable "post_confirmation_function_name" {
  description = "Name of the Post Confirmation Lambda. Created by modules/messaging; also referenced (as a deterministic ARN) by modules/identity's Cognito trigger."
  type        = string
  default     = "fn-post-confirmation"
}

variable "pipeline_artifacts_bucket_name" {
  description = "S3 bucket for CodePipeline artifacts. Created by modules/pipeline; also referenced by modules/security's IAM policy."
  type        = string
  default     = "hisaab-pipeline-artifacts-prod"
}

# --------------------------------------------------------------------------
# Known future-phase gaps (see docs/hisaab-infra-spec.md §17.1) — plain
# variables with no module wiring, since nothing in this codebase produces
# them yet.
# --------------------------------------------------------------------------

variable "profile_pics_bucket_name" {
  description = "Name of the profile pictures S3 bucket. No module in this codebase creates it yet — a future storage/delivery expansion."
  type        = string
  default     = "hisaab-profile-pics-prod"
}

variable "alb_5xx_alarm_name" {
  description = "Name of the ALB 5xx CloudWatch alarm CodeDeploy watches for auto-rollback. Created in modules/observability (phase 10), which doesn't exist yet in this codebase."
  type        = string
  default     = "alb-5xx-high"
}

# --------------------------------------------------------------------------
# modules/network
# --------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the Hisaab VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "hosted_zone_id" {
  description = "Existing, already-delegated Route 53 hosted zone ID to write records into"
  type        = string
  default     = "Z06937211L1EVF6QE14XW"
}

variable "rds_deletion_protection" {
  description = "Defaults to protected. Override to false (-var) only for a deliberate teardown — AWS hard-refuses to delete the instance while this is true, regardless of terraform destroy."
  type        = bool
  default     = true
}

variable "codestar_connection_arn" {
  description = "ARN of the GitHub CodeStar connection, owned by the standalone github-connection/ state so a destroy/rebuild of this environment never needs to re-run its one-time console OAuth authorization"
  type        = string
  default     = "arn:aws:codestar-connections:us-west-2:<AWS_ACCOUNT_ID>:connection/cd9621b4-9ff5-401d-8ac6-e87351fa7166"
}

variable "role_terraform_arn" {
  description = "ARN of role-terraform, owned by the standalone bootstrap/ state (applied once by hand) — same hardcoded-ARN-with-a-default pattern already used for codestar_connection_arn above, for the same reason: this is a separate root module/state, not wired in via a module block."
  type        = string
  default     = "arn:aws:iam::<AWS_ACCOUNT_ID>:role/role-terraform"
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC flow logs"
  type        = number
  default     = 14
}

# --------------------------------------------------------------------------
# modules/data
# --------------------------------------------------------------------------

variable "db_name" {
  description = "Initial database name created on the RDS instance"
  type        = string
  default     = "hisaab"
}

variable "db_master_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "hisaab_admin"
}

variable "db_master_password" {
  description = "Master password for the RDS instance, self-managed. No default on purpose (same reasoning as var.image_tag) — pass via -var at plan/apply time, never commit a real value."
  type        = string
  sensitive   = true
}

variable "db_master_password_version" {
  description = "Bump this to any new number to push a changed db_master_password value"
  type        = number
  default     = 1
}


# --------------------------------------------------------------------------
# modules/compute
# --------------------------------------------------------------------------

variable "image_tag" {
  description = <<-EOT
    Git commit SHA of the container image to pull, never "latest" (D6).
    No default on purpose: until modules/pipeline builds and pushes a real
    image, there is no valid tag to fall back to. Instances launched
    before then will fail to start a container and won't pass the ALB's
    /health check — a known, accepted gap until the app pipeline exists.
  EOT
  type        = string
}

variable "asg_min_size" {
  description = "ASG min size. Spec §6.2 calls for 2. Defaults to the spec value; override to 0 temporarily to stop the health-check-failure churn (no real container image exists yet) without changing what the code says the system should normally look like."
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "ASG desired capacity. Spec §6.2 calls for 2. Same override note as asg_min_size."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "ASG max size. Spec §6.2 calls for 4."
  type        = number
  default     = 4
}

variable "asg_bootstrapped" {
  description = "True once the seed ASG's first CodeDeploy blue/green deployment has succeeded. Defaults to true (this environment already has). Override to false only for a genuine from-scratch environment rebuild — see modules/compute's variables.tf for the full reasoning."
  type        = bool
  default     = true
}

variable "alb_logs_bucket_name" {
  description = "S3 bucket for ALB access logs"
  type        = string
  default     = "hisaab-alb-logs-prod"
}

variable "elb_service_account_id" {
  description = "AWS-owned account ID that delivers ELB access logs in this region (documented per-region constant, not a design choice)"
  type        = string
  default     = "797873946194" # us-west-2
}

# --------------------------------------------------------------------------
# modules/messaging
# --------------------------------------------------------------------------

variable "reminder_dispatcher_function_name" {
  description = "Name of the weekly reminder dispatcher Lambda"
  type        = string
  default     = "fn-reminder-dispatcher"
}

variable "reminder_schedule_expression" {
  description = "EventBridge Scheduler cron expression for the weekly reminder. Spec only says \"weekly\"; Monday 09:00 UTC is a default, not a spec requirement."
  type        = string
  default     = "cron(0 9 ? * MON *)"
}

# --------------------------------------------------------------------------
# modules/delivery
# --------------------------------------------------------------------------

variable "frontend_bucket_name" {
  description = "S3 bucket for the frontend SPA's static assets"
  type        = string
  default     = "hisaab-frontend-prod"
}

# --------------------------------------------------------------------------
# modules/pipeline
# --------------------------------------------------------------------------

variable "github_org" {
  description = "GitHub organization or user that owns the Hisaab repo"
  type        = string
  default     = "Asim-Iqbal-05"
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "Hisaab"
}

variable "github_branch" {
  description = "Branch the app pipeline deploys from"
  type        = string
  default     = "main"
}
