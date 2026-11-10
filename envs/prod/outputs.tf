output "vpc_id" {
  description = "Hisaab VPC ID"
  value       = module.network.vpc_id
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.compute.alb_dns_name
}

output "app_domain" {
  description = "Public API domain name"
  value       = module.compute.app_domain
}

output "frontend_domain" {
  description = "Public frontend domain name"
  value       = module.delivery.frontend_domain
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = module.delivery.cloudfront_domain_name
}

output "db_endpoint" {
  description = "RDS connection endpoint"
  value       = module.data.db_endpoint
}

output "db_secret_arn" {
  description = "ARN of the self-managed master password secret"
  value       = module.data.db_secret_arn
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint"
  value       = module.cache.redis_endpoint
}

output "image_tag" {
  description = "The image tag currently baked into the launch template. Read back by the infra pipeline before planning, so it always holds the currently-deployed app version steady rather than guessing or drifting it — the infra and app pipelines are deliberately decoupled (decision D10)."
  value       = var.image_tag
}

output "user_pool_id" {
  description = "Cognito user pool ID"
  value       = module.identity.user_pool_id
}

output "app_client_id" {
  description = "Cognito app client ID for the SPA"
  value       = module.identity.app_client_id
}

output "sqs_queue_url" {
  description = "URL of the hisaab-notifications SQS queue"
  value       = module.messaging.sqs_queue_url
}

output "ecr_repository_url" {
  description = "ECR repository URL to push images to"
  value       = module.pipeline.ecr_repository_url
}

output "codestar_connection_arn" {
  description = "CodeStar connection ARN — must be manually completed in the console before the pipeline can run"
  value       = module.pipeline.codestar_connection_arn
}

output "codestar_connection_status" {
  description = "Connection status — will read PENDING until manually completed in the console"
  value       = module.pipeline.codestar_connection_status
}

output "codepipeline_name" {
  description = "Name of the single combined pipeline (app deploy + self-mutating infra plan/apply)"
  value       = module.pipeline.codepipeline_name
}
