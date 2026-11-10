# ==========================================================================
# Profile pictures bucket — §8
# ==========================================================================
# Flagged as an unassigned gap throughout this build — role-ec2-hisaab's IAM
# policy (modules/security) has always referenced this bucket's ARN, but
# nothing created it. Created here since the EC2 role that reads/writes it
# lives in this module. Private; the browser never talks to it directly
# except via pre-signed PUT/GET URLs the API issues (§8, profile picture
# flow).

resource "aws_s3_bucket" "profile_pics" {
  bucket        = var.profile_pics_bucket_name
  force_destroy = false # Real user-uploaded content; don't make accidental deletion easy.

  tags = {
    Name    = var.profile_pics_bucket_name
    Project = "hisaab"
  }
}

resource "aws_s3_bucket_versioning" "profile_pics" {
  bucket = aws_s3_bucket.profile_pics.id

  versioning_configuration {
    status = "Enabled" # Spec §8: versioning enabled on state and profile pictures specifically.
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "profile_pics" {
  bucket = aws_s3_bucket.profile_pics.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "profile_pics" {
  bucket = aws_s3_bucket.profile_pics.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_cors_configuration" "profile_pics" {
  bucket = aws_s3_bucket.profile_pics.id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = ["https://hisaab.${var.parent_domain}"] # The frontend origin — browsers PUT directly via a pre-signed URL the API issues.
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_policy" "profile_pics" {
  bucket = aws_s3_bucket.profile_pics.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.profile_pics.arn,
          "${aws_s3_bucket.profile_pics.arn}/*",
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
