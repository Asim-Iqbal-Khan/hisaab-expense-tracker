output "user_pool_id" {
  description = "Cognito user pool ID"
  value       = aws_cognito_user_pool.hisaab.id
}

output "user_pool_arn" {
  description = "Cognito user pool ARN"
  value       = aws_cognito_user_pool.hisaab.arn
}

output "user_pool_endpoint" {
  description = "Cognito user pool endpoint, for JWKS/issuer configuration"
  value       = aws_cognito_user_pool.hisaab.endpoint
}

output "app_client_id" {
  description = "App client ID for the SPA — used both by the frontend's direct InitiateAuth calls and the backend's aws-jwt-verify clientId check"
  value       = aws_cognito_user_pool_client.web.id
}

output "post_confirmation_lambda_arn" {
  description = "ARN the Post Confirmation trigger is wired to (modules/messaging must create fn-post-confirmation under this exact name)"
  value       = local.post_confirmation_lambda_arn
}
