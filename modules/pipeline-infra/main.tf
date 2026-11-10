data "aws_caller_identity" "current" {}

locals {
  role_terraform_arn = var.role_terraform_arn
}
