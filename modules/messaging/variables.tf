variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

variable "sqs_queue_name" {
  description = "Name of the SQS notifications queue"
  type        = string
  default     = "hisaab-notifications"
}

variable "post_confirmation_function_name" {
  description = "Name of the Post Confirmation Lambda — must match modules/identity's deterministic ARN construction exactly"
  type        = string
  default     = "fn-post-confirmation"
}

variable "reminder_dispatcher_function_name" {
  description = "Name of the weekly reminder dispatcher Lambda"
  type        = string
  default     = "fn-reminder-dispatcher"
}

variable "email_sender_function_name" {
  description = "Name of the SQS-triggered email-sending Lambda"
  type        = string
  default     = "fn-email-sender"
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID, from modules/network — for the SES domain verification/DKIM records"
  type        = string
}

variable "parent_domain" {
  description = "Domain of the existing hosted zone the app lives under — the SES sending identity is hisaab.<parent_domain>, reusing the frontend's domain"
  type        = string
  default     = "example.com"
}

variable "reminder_schedule_expression" {
  description = "EventBridge Scheduler cron expression for the weekly reminder. Spec only says \"weekly\"; Monday 09:00 UTC is my choice, not a spec requirement."
  type        = string
  default     = "cron(0 9 ? * MON *)"
}

variable "subnet_ids" {
  description = "Map of subnet name to subnet ID, from modules/network"
  type        = map(string)
}

variable "sg_lambda_id" {
  description = "sg-lambda security group ID, from modules/security"
  type        = string
}

variable "db_endpoint" {
  description = "RDS endpoint (\"<host>:<port>\"), from modules/data"
  type        = string
}

variable "db_replica_endpoint" {
  description = "Read replica endpoint (\"<host>:<port>\"), from modules/data — used only by fn-reminder-dispatcher"
  type        = string
}

variable "db_name" {
  description = "RDS database name, from modules/data"
  type        = string
}

variable "db_secret_arn" {
  description = "RDS master password secret ARN, from modules/data — fn-post-confirmation reads this at invocation time to connect to Postgres"
  type        = string
}

variable "user_pool_arn" {
  description = "Cognito user pool ARN, from modules/identity"
  type        = string
}

variable "role_lambda_postconfirm_arn" {
  description = "ARN of role-lambda-postconfirm, from modules/security"
  type        = string
}

variable "role_lambda_reminder_arn" {
  description = "ARN of role-lambda-reminder, from modules/security"
  type        = string
}

variable "role_lambda_email_sender_arn" {
  description = "ARN of role-lambda-email-sender, from modules/security"
  type        = string
}
