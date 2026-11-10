output "ecr_repository_url" {
  description = "ECR repository URL to push images to"
  value       = aws_ecr_repository.hisaab_api.repository_url
}

output "codestar_connection_arn" {
  description = "CodeStar connection ARN, passed through from var.codestar_connection_arn"
  value       = var.codestar_connection_arn
}

output "codestar_connection_status" {
  description = "Connection status — PENDING until manually authorized once in the console, AVAILABLE after"
  value       = data.aws_codestarconnections_connection.github.connection_status
}

output "codepipeline_name" {
  description = "Name of the app deployment pipeline"
  value       = aws_codepipeline.hisaab_app.name
}

output "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group name"
  value       = aws_codedeploy_deployment_group.hisaab_api.deployment_group_name
}
