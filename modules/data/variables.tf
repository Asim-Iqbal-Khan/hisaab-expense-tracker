variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

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
  description = "Master password for the RDS instance, self-managed (no default on purpose — same reasoning as var.image_tag, a real credential should never have one lying around, even for a personal project). Pass via -var at plan/apply time."
  type        = string
  sensitive   = true
}

variable "db_master_password_version" {
  description = "Bump this to any new number to push a changed db_master_password value — write-only attributes can't be diffed against their old value directly, so this version number is what actually tells Terraform something changed"
  type        = number
  default     = 1
}

variable "subnet_ids" {
  description = "Map of subnet name to subnet ID, from modules/network"
  type        = map(string)
}

variable "sg_data_id" {
  description = "sg-data security group ID, from modules/security"
  type        = string
}

variable "role_ec2_hisaab_name" {
  description = "Name of role-ec2-hisaab, from modules/security"
  type        = string
}

variable "role_lambda_postconfirm_name" {
  description = "Name of role-lambda-postconfirm, from modules/security"
  type        = string
}

variable "role_lambda_reminder_name" {
  description = "Name of role-lambda-reminder, from modules/security"
  type        = string
}

variable "rds_deletion_protection" {
  description = "Defaults to protected. Override to false (e.g. -var) only for a deliberate teardown — AWS hard-refuses to delete the instance while this is true, regardless of terraform destroy."
  type        = bool
  default     = true
}
