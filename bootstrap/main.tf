# ------------------------------------------------------------------------
# Terraform state bucket
# ------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  tags = {
    Name    = var.state_bucket_name
    Project = "hisaab"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*",
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

# ------------------------------------------------------------------------
# Terraform state lock table
# ------------------------------------------------------------------------

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name    = var.lock_table_name
    Project = "hisaab"
  }
}

# ------------------------------------------------------------------------
# role-terraform — assumed by the infra pipeline's CodeBuild projects
# ------------------------------------------------------------------------
# Originally scaffolded for GitHub Actions OIDC federation, before the
# infra pipeline's actual design was settled as AWS CodePipeline/CodeBuild
# (matching the app pipeline's own tooling) rather than GitHub Actions
# directly. Repurposed rather than left dead or duplicated: CodeBuild
# projects assume a service role natively (no federation/identity-token
# exchange needed at all, unlike GitHub Actions reaching into AWS from
# outside it) — simpler trust relationship for what turned out to be the
# real requirement.

resource "aws_iam_role" "terraform" {
  name = "role-terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "codebuild.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = {
    Name    = "role-terraform"
    Project = "hisaab"
  }
}

# Broad but scoped to this account, per spec §11. Explicit denies below take
# precedence over the managed AdministratorAccess grant regardless of
# statement order (IAM: explicit deny always wins).
resource "aws_iam_role_policy_attachment" "terraform_admin" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy" "terraform_guardrails" {
  name = "deny-iam-user-and-root-operations"
  role = aws_iam_role.terraform.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyIamUserManagement"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:DeleteUser",
          "iam:UpdateUser",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:UpdateAccessKey",
          "iam:CreateLoginProfile",
          "iam:UpdateLoginProfile",
          "iam:DeleteLoginProfile",
          "iam:AttachUserPolicy",
          "iam:DetachUserPolicy",
          "iam:PutUserPolicy",
          "iam:DeleteUserPolicy",
          "iam:AddUserToGroup",
          "iam:RemoveUserFromGroup",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyAccountAndOrgOperations"
        Effect = "Deny"
        Action = [
          "iam:CreateAccountAlias",
          "iam:DeleteAccountAlias",
          "iam:UpdateAccountPasswordPolicy",
          "iam:DeleteAccountPasswordPolicy",
          "organizations:*",
          "account:CloseAccount",
        ]
        Resource = "*"
      },
    ]
  })
}
