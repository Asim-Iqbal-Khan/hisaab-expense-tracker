variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

variable "codestar_connection_arn" {
  description = "ARN of the GitHub CodeStar connection, from the standalone github-connection/ state"
  type        = string
}

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

variable "ecr_repo_name" {
  description = "Name of the ECR repository — must match modules/security's ecr_repo_name exactly"
  type        = string
  default     = "hisaab-api"
}

variable "codebuild_project_name" {
  description = "Name of the CodeBuild project — must match modules/security's codebuild_project_name exactly"
  type        = string
  default     = "hisaab-api-build"
}

variable "codedeploy_app_name" {
  description = "Name of the CodeDeploy application — must match modules/security's codedeploy_app_name exactly"
  type        = string
  default     = "hisaab-api"
}

variable "pipeline_artifacts_bucket_name" {
  description = "S3 bucket for CodePipeline artifacts"
  type        = string
  default     = "hisaab-pipeline-artifacts-prod"
}

variable "alb_5xx_alarm_name" {
  description = "Name of the ALB 5xx CloudWatch alarm CodeDeploy watches for auto-rollback. Created in modules/observability (phase 10) — referenced here by name ahead of that, same deterministic-forward-reference pattern used elsewhere. Alarm names are just strings, so this plans fine even though the alarm doesn't exist yet; it simply won't trigger anything until phase 10 creates it."
  type        = string
  default     = "alb-5xx-high"
}

variable "role_codebuild_arn" {
  description = "ARN of role-codebuild, from modules/security"
  type        = string
}

variable "role_codedeploy_arn" {
  description = "ARN of role-codedeploy, from modules/security"
  type        = string
}

variable "role_codepipeline_arn" {
  description = "ARN of role-codepipeline, from modules/security"
  type        = string
}

variable "role_codepipeline_name" {
  description = "Name of role-codepipeline, from modules/security"
  type        = string
}

variable "asg_name" {
  description = "Name of the persistent ASG, from modules/compute"
  type        = string
}

variable "target_group_name" {
  description = "Name of the persistent target group, from modules/compute"
  type        = string
}

variable "frontend_bucket_name" {
  description = "Name of the frontend SPA's S3 bucket, from modules/delivery — CodeBuild syncs the built frontend here"
  type        = string
}

variable "cloudfront_distribution_id" {
  description = "CloudFront distribution ID, from modules/delivery — CodeBuild invalidates this after syncing new frontend assets"
  type        = string
}

variable "infra_plan_project_name" {
  description = "Name of the Plan CodeBuild project, from modules/pipeline-infra"
  type        = string
}

variable "infra_apply_project_name" {
  description = "Name of the Apply CodeBuild project, from modules/pipeline-infra"
  type        = string
}

variable "cognito_app_client_id" {
  description = "SPA app client ID, from modules/identity — baked into the frontend build as VITE_COGNITO_CLIENT_ID"
  type        = string
}

variable "canary_orchestrator_project_name" {
  description = "Name of the canary orchestrator CodeBuild project — must match modules/security's canary_codebuild_project_name exactly"
  type        = string
  default     = "hisaab-canary-orchestrator"
}

variable "role_codebuild_canary_arn" {
  description = "ARN of role-codebuild-canary, from modules/security"
  type        = string
}

variable "alb_listener_arn" {
  description = "ARN of the ALB HTTPS listener, from modules/compute — the canary orchestrator calls ModifyListener directly on this"
  type        = string
}

variable "blue_target_group_arn" {
  description = "ARN of tg-hisaab-blue, from modules/compute"
  type        = string
}

variable "canary_target_group_arn" {
  description = "ARN of tg-hisaab-canary, from modules/compute"
  type        = string
}

variable "canary_5xx_alarm_name" {
  description = "CloudWatch alarm name the canary orchestrator polls for 5xx breaches, from modules/compute"
  type        = string
}

variable "canary_latency_alarm_name" {
  description = "CloudWatch alarm name the canary orchestrator polls for latency breaches, from modules/compute"
  type        = string
}
