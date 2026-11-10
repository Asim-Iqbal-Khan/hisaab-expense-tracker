# ==========================================================================
# VPC
# ==========================================================================

resource "aws_vpc" "hisaab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "vpc-hisaab"
    Project = "hisaab"
  }
}

# ==========================================================================
# VPC flow logs (REJECT only, to CloudWatch Logs) — §3.1
# ==========================================================================

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/hisaab/vpc-flow-logs"
  retention_in_days = var.flow_log_retention_days

  tags = {
    Name    = "hisaab-vpc-flow-logs"
    Project = "hisaab"
  }
}

resource "aws_iam_role" "vpc_flow_logs" {
  name = "role-vpc-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "vpc-flow-logs.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = {
    Name    = "role-vpc-flow-logs"
    Project = "hisaab"
  }
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "vpc-flow-logs-publish"
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
      },
    ]
  })
}

resource "aws_flow_log" "hisaab" {
  vpc_id                   = aws_vpc.hisaab.id
  traffic_type             = "REJECT"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.vpc_flow_logs.arn
  iam_role_arn             = aws_iam_role.vpc_flow_logs.arn
  max_aggregation_interval = 600

  tags = {
    Name    = "flow-log-hisaab"
    Project = "hisaab"
  }
}

# ==========================================================================
# Subnets — §3.2
# ==========================================================================
# AZ choice is pinned by AZ ID, not name, so the mapping stays stable across
# accounts (AWS randomizes which physical AZ a given name maps to per
# account).

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-name"
    values = ["us-west-2a", "us-west-2b"]
  }
}

locals {
  az_name_to_id = zipmap(
    data.aws_availability_zones.available.names,
    data.aws_availability_zones.available.zone_ids,
  )

  subnets = {
    "sn-public-a" = { cidr = "10.0.0.0/24", az = "us-west-2a", tier = "public" }
    "sn-public-b" = { cidr = "10.0.1.0/24", az = "us-west-2b", tier = "public" }
    "sn-app-a"    = { cidr = "10.0.16.0/20", az = "us-west-2a", tier = "app" }
    "sn-app-b"    = { cidr = "10.0.32.0/20", az = "us-west-2b", tier = "app" }
    "sn-data-a"   = { cidr = "10.0.48.0/24", az = "us-west-2a", tier = "data" }
    "sn-data-b"   = { cidr = "10.0.49.0/24", az = "us-west-2b", tier = "data" }
  }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.hisaab.id
  cidr_block              = each.value.cidr
  availability_zone_id    = local.az_name_to_id[each.value.az]
  map_public_ip_on_launch = each.value.tier == "public"

  tags = {
    Name    = each.key
    Tier    = each.value.tier
    Project = "hisaab"
  }
}

# ==========================================================================
# Gateways — §3.3
# ==========================================================================

resource "aws_internet_gateway" "hisaab" {
  vpc_id = aws_vpc.hisaab.id

  tags = {
    Name    = "igw-hisaab"
    Project = "hisaab"
  }
}

# Regional availability mode: one VPC-scoped NAT gateway that automatically
# expands into an AZ when workloads appear there and contracts when they
# leave. Deliberately not subnet-scoped — do not add a subnet_id here.
resource "aws_nat_gateway" "hisaab" {
  vpc_id            = aws_vpc.hisaab.id
  availability_mode = "regional"
  connectivity_type = "public"

  tags = {
    Name    = "nat-hisaab"
    Project = "hisaab"
  }
}

# ==========================================================================
# Route tables — §3.4
# ==========================================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.hisaab.id

  tags = {
    Name    = "rt-public"
    Project = "hisaab"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.hisaab.id
}

# One shared application route table, not one per AZ — the operational
# payoff of regional NAT mode (decision D2). Every private app subnet routes
# to the same NAT gateway ID.
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.hisaab.id

  tags = {
    Name    = "rt-app"
    Project = "hisaab"
  }
}

resource "aws_route" "app_nat" {
  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.hisaab.id
}

# rt-data deliberately has no default route at all — the database tier has
# no path to the internet in either direction.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.hisaab.id

  tags = {
    Name    = "rt-data"
    Project = "hisaab"
  }
}

resource "aws_route_table_association" "this" {
  for_each = local.subnets

  subnet_id = aws_subnet.this[each.key].id
  route_table_id = (
    each.value.tier == "public" ? aws_route_table.public.id :
    each.value.tier == "app" ? aws_route_table.app.id :
    aws_route_table.data.id
  )
}

# ==========================================================================
# VPC endpoints — §3.5
# ==========================================================================

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.hisaab.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id]

  tags = {
    Name    = "vpce-s3"
    Project = "hisaab"
  }
}

# ==========================================================================
# DNS and certificates — §3.6, §3.7
# ==========================================================================
# The hosted zone already exists and is already delegated; it is looked up,
# never created. Only the ACM certificates and their DNS validation records
# are created here. The "hisaab." and "app.hisaab." alias records that
# point at CloudFront and the ALB are created alongside those resources in
# modules/delivery and modules/compute respectively — those targets don't
# exist yet in phase 1.

data "aws_route53_zone" "internship" {
  zone_id = var.hosted_zone_id
}

resource "aws_acm_certificate" "alb" {
  domain_name       = "app.hisaab.${var.parent_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name    = "cert-alb"
    Project = "hisaab"
  }
}

resource "aws_route53_record" "alb_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.internship.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.value]
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for r in aws_route53_record.alb_cert_validation : r.fqdn]
}

resource "aws_acm_certificate" "cloudfront" {
  provider = aws.us_east_1

  domain_name       = "hisaab.${var.parent_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name    = "cert-cloudfront"
    Project = "hisaab"
  }
}

resource "aws_route53_record" "cloudfront_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cloudfront.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.internship.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.value]
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for r in aws_route53_record.cloudfront_cert_validation : r.fqdn]
}
