# ==========================================================================
# Pipeline artifacts bucket — §8
# ==========================================================================
# Another storage-table bucket the build order never explicitly assigned
# to a phase (same situation as the ALB logs bucket in modules/compute).
# Created here since CodePipeline requires one to exist as its artifact
# store.

resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = var.pipeline_artifacts_bucket_name
  force_destroy = true # Pre-production environment; don't let a stray artifact block a future teardown.

  tags = {
    Name    = var.pipeline_artifacts_bucket_name
    Project = "hisaab"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  rule {
    id     = "expire-30-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.pipeline_artifacts.arn,
          "${aws_s3_bucket.pipeline_artifacts.arn}/*",
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
