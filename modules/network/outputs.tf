output "vpc_id" {
  description = "ID of the Hisaab VPC"
  value       = aws_vpc.hisaab.id
}

output "vpc_cidr" {
  description = "CIDR block of the Hisaab VPC"
  value       = aws_vpc.hisaab.cidr_block
}

output "subnet_ids" {
  description = "Map of subnet name to subnet ID"
  value       = { for k, s in aws_subnet.this : k => s.id }
}

output "subnet_tiers" {
  description = "Map of subnet name to tier (public, app, data)"
  value       = { for k, v in local.subnets : k => v.tier }
}

output "route_table_public_id" {
  description = "ID of rt-public"
  value       = aws_route_table.public.id
}

output "route_table_app_id" {
  description = "ID of rt-app"
  value       = aws_route_table.app.id
}

output "route_table_data_id" {
  description = "ID of rt-data"
  value       = aws_route_table.data.id
}

output "nat_gateway_id" {
  description = "ID of the regional NAT gateway"
  value       = aws_nat_gateway.hisaab.id
}

output "internet_gateway_id" {
  description = "ID of igw-hisaab"
  value       = aws_internet_gateway.hisaab.id
}

output "s3_vpc_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint"
  value       = aws_vpc_endpoint.s3.id
}

output "hosted_zone_id" {
  description = "Route 53 hosted zone ID records are written into"
  value       = data.aws_route53_zone.internship.zone_id
}

output "hosted_zone_name" {
  description = "Route 53 hosted zone domain name"
  value       = data.aws_route53_zone.internship.name
}

output "acm_certificate_alb_arn" {
  description = "Validated ARN of cert-alb (us-west-2), for the ALB HTTPS listener"
  value       = aws_acm_certificate_validation.alb.certificate_arn
}

output "acm_certificate_cloudfront_arn" {
  description = "Validated ARN of cert-cloudfront (us-east-1), for the CloudFront distribution"
  value       = aws_acm_certificate_validation.cloudfront.certificate_arn
}

output "flow_log_group_name" {
  description = "CloudWatch Logs group name for VPC flow logs"
  value       = aws_cloudwatch_log_group.vpc_flow_logs.name
}
