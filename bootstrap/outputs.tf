output "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state for all other modules"
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table_name" {
  description = "DynamoDB table used for Terraform state locking"
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "terraform_role_arn" {
  description = "ARN of role-terraform, assumed by the infra pipeline's CodeBuild projects"
  value       = aws_iam_role.terraform.arn
}
