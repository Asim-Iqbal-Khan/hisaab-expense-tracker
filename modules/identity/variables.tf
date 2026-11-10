variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

variable "post_confirmation_function_name" {
  description = "Name of the Post Confirmation Lambda, created by modules/messaging in phase 6. Shared by name so this module can wire the trigger via a deterministic ARN ahead of that phase."
  type        = string
  default     = "fn-post-confirmation"
}
