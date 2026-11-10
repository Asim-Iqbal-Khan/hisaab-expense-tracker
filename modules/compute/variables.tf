variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

variable "ecr_repo_name" {
  description = "Name of the ECR repository, created by modules/pipeline in phase 8"
  type        = string
  default     = "hisaab-api"
}

variable "profile_pics_bucket_name" {
  description = "Name of the profile pictures S3 bucket — must match modules/security's profile_pics_bucket_name exactly"
  type        = string
  default     = "hisaab-profile-pics-prod"
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

variable "asg_bootstrapped" {
  description = "True once the very first CodeDeploy blue/green deployment has succeeded at least once. Before that, Terraform creates the seed ASG (and its scaling policy) so CodeDeploy's first COPY_AUTO_SCALING_GROUP copy has something to work from. After that, CodeDeploy permanently owns ASG identity — every successful deployment deletes whatever Terraform-managed ASG it copied from and replaces it with its own dynamically-named one, entirely outside Terraform's knowledge (see the comment above aws_autoscaling_group.hisaab). Leaving the seed resource declared unconditionally meant every later apply, forever, saw it 'missing' and proposed recreating it — wasteful (two idle EC2 instances, since the seed is deliberately never attached to a target group) and unsafe for a pipeline that applies without a human re-reading every line each time. Flip this to false only for a genuine from-scratch environment rebuild — same one-time-bootstrap shape already used for bootstrap/ itself."
  type        = bool
  default     = true
}

variable "asg_max_size" {
  description = "ASG max size. Spec §6.2 calls for 4."
  type        = number
  default     = 4
}

variable "image_tag" {
  description = <<-EOT
    Git commit SHA of the container image to pull, never "latest" (D6).
    No default on purpose: until modules/pipeline (phase 8) builds and
    pushes a real image, there is no valid tag to fall back to. Instances
    launched before then will fail to start a container and won't pass the
    ALB's /health check — a known, accepted gap until phase 8 exists.
  EOT
  type        = string
}

variable "alb_logs_bucket_name" {
  description = "S3 bucket for ALB access logs"
  type        = string
  default     = "hisaab-alb-logs-prod"
}

variable "parent_domain" {
  description = "Domain of the existing hosted zone the app lives under"
  type        = string
  default     = "example.com"
}

variable "elb_service_account_id" {
  description = "AWS-owned account ID that delivers ELB access logs in this region (documented per-region constant, not a design choice)"
  type        = string
  default     = "797873946194" # us-west-2
}

variable "subnet_ids" {
  description = "Map of subnet name to subnet ID, from modules/network"
  type        = map(string)
}

variable "vpc_id" {
  description = "VPC ID, from modules/network"
  type        = string
}

variable "acm_certificate_alb_arn" {
  description = "Validated cert-alb ARN, from modules/network"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID, from modules/network"
  type        = string
}

variable "sg_app_id" {
  description = "sg-app security group ID, from modules/security"
  type        = string
}

variable "sg_alb_id" {
  description = "sg-alb security group ID, from modules/security"
  type        = string
}

variable "instance_profile_ec2_hisaab_name" {
  description = "EC2 instance profile name for role-ec2-hisaab, from modules/security"
  type        = string
}

variable "db_endpoint" {
  description = "RDS endpoint (\"<host>:<port>\"), from modules/data"
  type        = string
}

variable "db_name" {
  description = "RDS database name, from modules/data"
  type        = string
}

variable "db_secret_arn" {
  description = "RDS master password secret ARN, from modules/data"
  type        = string
}

variable "cognito_user_pool_id" {
  description = "Cognito user pool ID, from modules/identity — passed to the backend so it can build the JWKS URL for token verification"
  type        = string
}

variable "cognito_app_client_id" {
  description = "SPA app client ID, from modules/identity — passed to the backend for aws-jwt-verify's clientId check"
  type        = string
}

variable "sqs_queue_url" {
  description = "URL of the hisaab-notifications SQS queue, from modules/messaging"
  type        = string
}

variable "redis_host" {
  description = "Endpoint of the ElastiCache Redis replication group, from modules/cache"
  type        = string
}

variable "redis_port" {
  description = "Port of the ElastiCache Redis replication group, from modules/cache"
  type        = number
}

variable "role_codedeploy_name" {
  description = "Name of role-codedeploy, from modules/security — this module attaches an ec2:RunInstances permission onto it once the launch template's ARN exists (same deferred-permission pattern modules/data uses for the RDS secret)"
  type        = string
}

variable "role_codebuild_canary_name" {
  description = "Name of role-codebuild-canary, from modules/security — this module attaches an elasticloadbalancing:ModifyListener permission onto it once the listener's ARN exists (same deferred-permission pattern as role_codedeploy_name above)"
  type        = string
}
