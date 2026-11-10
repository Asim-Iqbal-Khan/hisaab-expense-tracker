variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

variable "vpc_id" {
  description = "VPC ID from modules/network, security groups are attached to it"
  type        = string
}

variable "ecr_repo_name" {
  description = "Name of the ECR repository, created by modules/pipeline in phase 8"
  type        = string
  default     = "hisaab-api"
}

variable "sqs_queue_name" {
  description = "Name of the SQS notifications queue, created by modules/messaging in phase 6"
  type        = string
  default     = "hisaab-notifications"
}

variable "codebuild_project_name" {
  description = "Name of the CodeBuild project, created by modules/pipeline in phase 8"
  type        = string
  default     = "hisaab-api-build"
}

variable "codedeploy_app_name" {
  description = "Name of the CodeDeploy application, created by modules/pipeline in phase 8"
  type        = string
  default     = "hisaab-api"
}

variable "canary_codebuild_project_name" {
  description = "Name of the canary orchestrator CodeBuild project, created by modules/pipeline"
  type        = string
  default     = "hisaab-canary-orchestrator"
}

variable "profile_pics_bucket_name" {
  description = "Name of the profile pictures S3 bucket. No module in this codebase creates it yet — a known gap for a future storage/delivery expansion (see docs/hisaab-infra-spec.md §17.1)."
  type        = string
  default     = "hisaab-profile-pics-prod"
}

variable "pipeline_artifacts_bucket_name" {
  description = "Name of the CodePipeline artifacts bucket, created by modules/pipeline"
  type        = string
  default     = "hisaab-pipeline-artifacts-prod"
}

variable "frontend_bucket_name" {
  description = "Name of the frontend SPA's S3 bucket, created by modules/delivery — role-codebuild needs write access to deploy the built frontend"
  type        = string
  default     = "hisaab-frontend-prod"
}
