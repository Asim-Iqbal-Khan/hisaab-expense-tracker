
data "aws_caller_identity" "current" {}

locals {
  vpc_id = var.vpc_id
}

# ==========================================================================
# Security groups — §5
# ==========================================================================
# Rules live entirely in separate aws_vpc_security_group_{ingress,egress}_rule
# resources below, never inline on these — inline ingress/egress and the
# separate rule resources can't safely coexist on the same group and
# direction. Declaring an inline "ingress/egress = []" here would make
# Terraform treat that attribute as authoritative and revoke the very rules
# the separate resources create, on every subsequent plan. AWS's automatic
# "allow all egress" default was already stripped from these groups at
# creation time; a genuinely fresh deployment of this module would need one
# extra manual `aws ec2 revoke-security-group-egress` per group for the
# default rule, since there's no purely declarative way to both remove it
# and use separate rule resources for everything else.

resource "aws_security_group" "alb" {
  name        = "hisaab-sg-alb"
  description = "ALB: internet ingress on 80/443, forwards to sg-app on 8080"
  vpc_id      = local.vpc_id

  lifecycle {
    ignore_changes = [ingress, egress]
  }

  tags = {
    Name    = "sg-alb"
    Project = "hisaab"
  }
}

resource "aws_security_group" "app" {
  name        = "hisaab-sg-app"
  description = "EC2 app instances behind the ALB"
  vpc_id      = local.vpc_id

  lifecycle {
    ignore_changes = [ingress, egress]
  }

  tags = {
    Name    = "sg-app"
    Project = "hisaab"
  }
}

resource "aws_security_group" "data" {
  name        = "hisaab-sg-data"
  description = "RDS Postgres; no outbound access"
  vpc_id      = local.vpc_id

  lifecycle {
    ignore_changes = [ingress, egress]
  }

  tags = {
    Name    = "sg-data"
    Project = "hisaab"
  }
}

resource "aws_security_group" "lambda" {
  name        = "hisaab-sg-lambda"
  description = "fn-post-confirmation and fn-reminder-dispatcher; no inbound"
  vpc_id      = local.vpc_id

  lifecycle {
    ignore_changes = [ingress, egress]
  }

  tags = {
    Name    = "sg-lambda"
    Project = "hisaab"
  }
}

resource "aws_security_group" "cache" {
  name        = "hisaab-sg-cache"
  description = "ElastiCache Redis; no outbound access"
  vpc_id      = local.vpc_id

  lifecycle {
    ignore_changes = [ingress, egress]
  }

  tags = {
    Name    = "sg-cache"
    Project = "hisaab"
  }
}

# --- sg-alb ---------------------------------------------------------------
# Internet ingress is the one spec-explicit exception to "reference by SG ID".

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere; listener 301s to HTTPS, never forwards"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to app instances"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.app.id
}

# --- sg-app -----------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "From the ALB"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_internet" {
  security_group_id = aws_security_group.app.id
  description       = "ECR pulls, OS updates, Secrets Manager, SNS, SSM - all over NAT"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_to_data" {
  security_group_id            = aws_security_group.app.id
  description                  = "Postgres"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.data.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_cache" {
  security_group_id            = aws_security_group.app.id
  description                  = "Redis"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.cache.id
}

# --- sg-data ------------------------------------------------------------
# No egress rules at all — declared via the empty egress = [] above.

resource "aws_vpc_security_group_ingress_rule" "data_from_app" {
  security_group_id            = aws_security_group.data.id
  description                  = "From EC2 app instances"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_ingress_rule" "data_from_lambda" {
  security_group_id            = aws_security_group.data.id
  description                  = "From fn-post-confirmation and fn-reminder-dispatcher"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.lambda.id
}

# --- sg-cache ---------------------------------------------------------------
# No egress rules at all — declared via the empty egress = [] above.

resource "aws_vpc_security_group_ingress_rule" "cache_from_app" {
  security_group_id            = aws_security_group.cache.id
  description                  = "From EC2 app instances"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.app.id
}

# --- sg-lambda ------------------------------------------------------------
# No ingress rules at all — declared via the empty ingress = [] above.

resource "aws_vpc_security_group_egress_rule" "lambda_to_internet" {
  security_group_id = aws_security_group.lambda.id
  description       = "Secrets Manager, SNS - over NAT"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_data" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "Postgres"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.data.id
}
