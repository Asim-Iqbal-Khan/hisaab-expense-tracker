variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

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

variable "parent_domain" {
  description = "Domain of the existing hosted zone (project records live under the hisaab. prefix)"
  type        = string
  default     = "example.com"
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC flow logs"
  type        = number
  default     = 14
}
