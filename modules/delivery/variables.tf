variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

variable "frontend_bucket_name" {
  description = "S3 bucket for the frontend SPA's static assets"
  type        = string
  default     = "hisaab-frontend-prod"
}

variable "parent_domain" {
  description = "Domain of the existing hosted zone the app lives under"
  type        = string
  default     = "example.com"
}

variable "acm_certificate_cloudfront_arn" {
  description = "Validated cert-cloudfront ARN (us-east-1), from modules/network"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID, from modules/network"
  type        = string
}

variable "alb_origin_domain" {
  description = "Public API domain name (the ALB, via app.hisaab...), from modules/compute. CloudFront proxies /api/* and /oauth2/* to this origin so the frontend and API share one origin — required for the ALB's authenticate-cognito session cookie to be usable by the SPA's same-site fetch() calls."
  type        = string
}

variable "role_codebuild_name" {
  description = "Name of role-codebuild, from modules/security — this module attaches a CloudFront invalidation permission onto it once the distribution ARN exists (same deferred-permission pattern modules/data uses for the RDS secret)"
  type        = string
}
