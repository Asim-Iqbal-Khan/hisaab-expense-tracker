output "infra_plan_project_name" {
  description = "Name of the Plan CodeBuild project"
  value       = aws_codebuild_project.infra_plan.name
}

output "infra_apply_project_name" {
  description = "Name of the Apply CodeBuild project"
  value       = aws_codebuild_project.infra_apply.name
}
