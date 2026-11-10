# ==========================================================================
# ALB access log bucket — §8
# ==========================================================================
# Not explicitly assigned to a phase in the build order's storage table;
# created here because the ALB needs it to exist (with the right bucket
# policy) before access logging can be enabled at all. Same "create the
# tightly-coupled supporting resource where it's needed" pattern already
# used for the flow-logs log group (network) and the monitoring role (data).

resource "aws_s3_bucket" "alb_logs" {
  bucket        = var.alb_logs_bucket_name
  force_destroy = true # This bucket receives real traffic logs; don't let a stray object block a future teardown.

  tags = {
    Name    = var.alb_logs_bucket_name
    Project = "hisaab"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-90-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowElbLogDelivery"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.elb_service_account_id}:root"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.alb_logs.arn,
          "${aws_s3_bucket.alb_logs.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })
}

# ==========================================================================
# Application load balancer — §6.3
# ==========================================================================

resource "aws_lb" "hisaab" {
  name               = "alb-hisaab"
  load_balancer_type = "application"
  internal           = false
  subnets            = local.public_subnet_ids
  security_groups    = [local.sg_alb_id]

  idle_timeout               = 60
  enable_deletion_protection = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]

  tags = {
    Name    = "alb-hisaab"
    Project = "hisaab"
  }
}

# ==========================================================================
# Target group tg-hisaab-blue — §6.3
# ==========================================================================
# The full-fleet target group. CodeDeploy's EC2/"Server"-platform blue/green
# mechanism (target_group_info in modules/pipeline, confirmed against AWS's
# own API docs) shifts traffic by registering the temporary replacement
# fleet's instances into this same target group and deregistering the old
# ones — not by swapping the listener between two target groups. That
# pair-swap model (target_group_pair_info) is ECS/Lambda-only, which is
# exactly why tg-hisaab-canary below exists as a separate, manually-weighted
# target group instead of trying to get CodeDeploy to manage a canary split.

resource "aws_lb_target_group" "hisaab" {
  name     = "tg-hisaab-blue"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  deregistration_delay = 30

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    protocol            = "HTTP"
    matcher             = "200"
  }

  tags = {
    Name    = "tg-hisaab-blue"
    Project = "hisaab"
  }
}

# ==========================================================================
# Target group tg-hisaab-canary
# ==========================================================================
# Fronts the single always-on canary instance (aws_autoscaling_group.canary
# in main.tf). Same health check as tg-hisaab-blue — a canary that can't
# pass the same bar isn't a useful signal. Traffic only ever reaches this
# target group via the weighted listener below, and only while the canary
# CodeBuild orchestrator has deliberately raised its weight above 0 during a
# deploy's traffic ramp.

resource "aws_lb_target_group" "canary" {
  name     = "tg-hisaab-canary"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  deregistration_delay = 30

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    protocol            = "HTTP"
    matcher             = "200"
  }

  tags = {
    Name    = "tg-hisaab-canary"
    Project = "hisaab"
  }
}

# ==========================================================================
# Canary alarms
# ==========================================================================
# First CloudWatch alarms in this repo. Deliberately scoped to just
# tg-hisaab-canary (TargetGroup dimension), not the whole ALB — a regression
# only visible in the canary's own slice of traffic must not get diluted
# into an aggregate metric where 90%+ of requests are still hitting healthy
# tg-hisaab-blue instances. The canary orchestrator polls these via
# DescribeAlarms between each weight-ramp step; nothing subscribes to them
# (no SNS topic) since a human isn't meant to be paged mid-ramp — the
# orchestrator itself is the responder.
#
# treat_missing_data = "notBreaching": the canary sits at 0% traffic between
# deploys, so most periods report no data points at all. That must read as
# "nothing to alarm about," not as a breach.

resource "aws_cloudwatch_metric_alarm" "canary_5xx" {
  alarm_name          = "canary-5xx-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.hisaab.arn_suffix
    TargetGroup  = aws_lb_target_group.canary.arn_suffix
  }

  tags = {
    Name    = "canary-5xx-high"
    Project = "hisaab"
  }
}

resource "aws_cloudwatch_metric_alarm" "canary_latency" {
  alarm_name          = "canary-latency-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.hisaab.arn_suffix
    TargetGroup  = aws_lb_target_group.canary.arn_suffix
  }

  tags = {
    Name    = "canary-latency-high"
    Project = "hisaab"
  }
}

# ==========================================================================
# Listeners — §6.3
# ==========================================================================

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.hisaab.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_alb_arn

  # Auth is app-side now, not gated at the load balancer: the frontend
  # authenticates directly against Cognito and sends a Bearer token, which
  # the backend verifies against Cognito's JWKS (backend/src/auth.ts). This
  # listener is a plain forward — no authenticate-cognito action, no Hosted
  # UI redirect. (An earlier version gated every request here via ALB's
  # native authenticate-cognito action; removed once the decision was made
  # to build login/signup in the frontend instead of using Hosted UI.)
  #
  # Weighted forward across both target groups, not a single target_group_arn
  # — this is the one piece of AWS-native traffic control CodeDeploy's
  # EC2/"Server" platform can't give us (target_group_pair_info is
  # ECS/Lambda-only), so the canary orchestrator (modules/pipeline) moves
  # these weights directly via ModifyListener instead, mid-deploy.
  #
  # No ignore_changes here, deliberately — unlike autoscaling_groups on the
  # CodeDeploy deployment group (which points at a dynamically-named ASG
  # Terraform doesn't create), the orchestrator always resets weights back
  # to exactly this 100/0 baseline when it finishes, pass or fail. There's
  # nothing for Terraform to fight: the only moment real AWS state could
  # differ from this config is transiently, mid-ramp, and this pipeline's
  # Apply stage runs well before Canary/Deploy — the two never overlap.
  default_action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.hisaab.arn
        weight = 100
      }
      target_group {
        arn    = aws_lb_target_group.canary.arn
        weight = 0
      }
    }
  }

  tags = {
    Name    = "alb-hisaab-listener-443"
    Project = "hisaab"
  }
}

# ==========================================================================
# Canary orchestrator permission — deferred from modules/security
# ==========================================================================
# elasticloadbalancing:ModifyListener couldn't be scoped in modules/security
# because this listener's AWS-generated ARN didn't exist yet there — same
# deferred-permission pattern as codedeploy_run_instances above.

resource "aws_iam_role_policy" "codebuild_canary_modify_listener" {
  name = "role-codebuild-canary-modify-listener"
  role = var.role_codebuild_canary_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ShiftCanaryTraffic"
        Effect   = "Allow"
        Action   = "elasticloadbalancing:ModifyListener"
        Resource = aws_lb_listener.https.arn
      },
    ]
  })
}

# ==========================================================================
# DNS — §3.6
# ==========================================================================
# Deferred from modules/network (phase 1): this alias needs the ALB, which
# didn't exist yet in phase 1.

resource "aws_route53_record" "app_alias" {
  zone_id = var.hosted_zone_id
  name    = "app.hisaab.${var.parent_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.hisaab.dns_name
    zone_id                = aws_lb.hisaab.zone_id
    evaluate_target_health = true
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.hisaab.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = {
    Name    = "alb-hisaab-listener-80"
    Project = "hisaab"
  }
}
