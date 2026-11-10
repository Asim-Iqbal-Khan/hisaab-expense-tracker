# ==========================================================================
# Frontend bucket — §8
# ==========================================================================
# Private, no S3 website endpoint, never publicly readable. CloudFront
# reaches it only through the Origin Access Control below. Spec's "SSE-S3
# encryption minimum, versioning enabled on state and profile pictures"
# scopes versioning to those two buckets specifically — not this one.

resource "aws_s3_bucket" "frontend" {
  bucket        = var.frontend_bucket_name
  force_destroy = true # Pre-production environment; don't let a stray uploaded asset block a future teardown.

  tags = {
    Name    = var.frontend_bucket_name
    Project = "hisaab"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.frontend.arn,
          "${aws_s3_bucket.frontend.arn}/*",
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
# Origin Access Control — §8
# ==========================================================================

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "oac-hisaab-frontend"
  description                       = "OAC for hisaab-frontend-prod"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ==========================================================================
# SPA fallback — CloudFront Function, not custom_error_response
# ==========================================================================
# custom_error_response applies to the whole distribution, not per-behavior
# — it can't tell "a 404 from the S3 frontend origin, which needs the SPA
# shell" apart from "a 404 from the ALB API origin, which is a real API
# response". Confirmed the hard way: it was rewriting /api/me's genuine
# 404 (no profile row yet) into a 200 + index.html, and the frontend then
# tried to JSON-parse the HTML shell. Rewriting the request URI before it
# ever reaches the origin, and only on the default (S3) behavior, avoids
# the collision entirely — /api/* and /oauth2/* never run through this.

resource "aws_cloudfront_function" "spa_fallback" {
  name    = "hisaab-spa-fallback"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrite extensionless paths to /index.html for SPA client-side routing"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      if (!request.uri.includes('.')) {
        request.uri = '/index.html';
      }
      return request;
    }
  EOT
}

# ==========================================================================
# CloudFront distribution — §8
# ==========================================================================

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  comment             = "hisaab frontend"

  aliases = ["hisaab.${var.parent_domain}"]

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-hisaab-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # ALB origin — a plain reverse proxy for /api/*, unifying the frontend
  # and API under one origin. Auth is Bearer-token-based now (the frontend
  # authenticates directly against Cognito and attaches the token itself),
  # so this isn't load-bearing for auth the way it used to be when ALB set
  # a same-origin session cookie — kept anyway since it avoids CORS
  # handling entirely and every existing frontend fetch() call already
  # uses a relative /api/* path. Must dial app.hisaab... — cert-alb only
  # covers that SAN, not hisaab... itself.
  origin {
    domain_name = var.alb_origin_domain
    origin_id   = "alb-hisaab-api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-hisaab-frontend"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed: CachingOptimized

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_fallback.arn
    }
  }

  # /api/* — the JSON API, proxied uncached to the ALB. No /oauth2/*
  # behavior anymore — that was ALB's fixed OAuth callback path
  # (/oauth2/idpresponse), dead now that there's no Hosted UI redirect to
  # complete. origin_request_policy forwards the real Host header and any
  # headers/cookies the viewer sends; harmless to keep even though nothing
  # here depends on cookies anymore.
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "alb-hisaab-api"
    viewer_protocol_policy   = "redirect-to-https"
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS managed: CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AWS managed: AllViewer
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_cloudfront_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name    = "cf-hisaab"
    Project = "hisaab"
  }
}

# ==========================================================================
# CodeBuild permission — deferred from modules/security
# ==========================================================================
# cloudfront:CreateInvalidation couldn't be scoped in modules/security
# because the distribution's AWS-generated ARN didn't exist yet. Attached
# here, now that it does — same deferred-permission pattern modules/data
# uses for the RDS secret-read grant on role-ec2-hisaab.

resource "aws_iam_role_policy" "codebuild_cloudfront_invalidation" {
  name = "role-codebuild-cloudfront-invalidation"
  role = var.role_codebuild_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvalidateFrontendDistribution"
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = aws_cloudfront_distribution.frontend.arn
      },
    ]
  })
}

# ==========================================================================
# DNS — §3.6
# ==========================================================================
# Deferred from modules/network (phase 1): this alias needs the CloudFront
# distribution, which didn't exist yet in phase 1.

resource "aws_route53_record" "frontend_alias" {
  zone_id = var.hosted_zone_id
  name    = "hisaab.${var.parent_domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}
