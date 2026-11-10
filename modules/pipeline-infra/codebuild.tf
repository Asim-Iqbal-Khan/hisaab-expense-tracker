# ==========================================================================
# CodeBuild projects — infra pipeline
# ==========================================================================
# Two projects, not one reused with overridden commands — matches the
# GitHub Actions design this replaced (a distinct Plan job and Apply job)
# and keeps each buildspec doing exactly one thing.
#
# Both use role-terraform (bootstrap/) as their service role, not
# role-codebuild (which is deliberately narrow — ECR push + S3 artifact
# access only, built for the app pipeline). Planning or applying arbitrary
# infrastructure changes genuinely needs the broad-but-guarded permissions
# role-terraform carries.

resource "aws_codebuild_project" "infra_plan" {
  name          = "hisaab-infra-plan"
  description   = "terraform fmt/validate/plan for envs/prod, plan saved as a pipeline artifact"
  service_role  = local.role_terraform_arn
  build_timeout = 15

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    # Read directly from Secrets Manager, not a manually-entered pipeline
    # secret — this is the same self-managed secret modules/data created
    # for the RDS primary itself, so there's exactly one place this
    # password lives, not two.
    environment_variable {
      name  = "DB_MASTER_PASSWORD"
      type  = "SECRETS_MANAGER"
      value = "${var.db_master_password_secret_arn}:password"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "infra-plan-buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/hisaab-infra-plan"
    }
  }

  tags = {
    Name    = "hisaab-infra-plan"
    Project = "hisaab"
  }
}

resource "aws_codebuild_project" "infra_apply" {
  name          = "hisaab-infra-apply"
  description   = "terraform apply, running the exact plan the Plan stage produced and a human approved — never a fresh plan"
  service_role  = local.role_terraform_arn
  build_timeout = 30 # RDS/ASG-touching applies can genuinely take a while

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "infra-apply-buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/hisaab-infra-apply"
    }
  }

  tags = {
    Name    = "hisaab-infra-apply"
    Project = "hisaab"
  }
}
