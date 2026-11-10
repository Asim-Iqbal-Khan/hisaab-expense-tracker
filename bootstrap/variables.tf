variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

variable "state_bucket_name" {
  description = "S3 bucket for Terraform remote state"
  type        = string
  default     = "hisaab-tfstate"
}

variable "lock_table_name" {
  description = "DynamoDB table for Terraform state locking"
  type        = string
  default     = "hisaab-tfstate-lock"
}
