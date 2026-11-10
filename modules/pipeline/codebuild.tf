# ==========================================================================
# CodeBuild project — §12.1
# ==========================================================================
# buildspec = "buildspec.yml" tells CodeBuild to look for that file at the
# root of the checked-out source. It builds+pushes the backend Docker
# image (tag = commit SHA, per D6) and, in the same run, builds the
# frontend and syncs it to hisaab-frontend-prod + invalidates CloudFront —
# there's no separate frontend pipeline stage, since an S3 sync isn't a
# CodeDeploy-managed rollout.

resource "aws_codebuild_project" "hisaab_api" {
  name          = var.codebuild_project_name
  description   = "Builds and pushes the Hisaab API image, tagged by commit SHA"
  service_role  = local.role_codebuild_arn
  build_timeout = 15

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0" # Must match the servers' architecture (modules/compute, x86_64/t3.micro) — CodeBuild builds the image the ASG actually runs
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # Required to run `docker build` inside CodeBuild

    environment_variable {
      name  = "ECR_REPOSITORY_URL"
      value = aws_ecr_repository.hisaab_api.repository_url
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }

    environment_variable {
      name  = "FRONTEND_BUCKET_NAME"
      value = var.frontend_bucket_name
    }

    environment_variable {
      name  = "CLOUDFRONT_DISTRIBUTION_ID"
      value = var.cloudfront_distribution_id
    }

    # Vite bakes these into the frontend bundle at build time (any
    # VITE_-prefixed process env var is picked up automatically) so the
    # SPA knows which Cognito app client/region to call directly —
    # frontend-driven auth, no Hosted UI.
    environment_variable {
      name  = "VITE_COGNITO_CLIENT_ID"
      value = var.cognito_app_client_id
    }

    environment_variable {
      name  = "VITE_COGNITO_REGION"
      value = var.aws_region
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/${var.codebuild_project_name}"
    }
  }

  tags = {
    Name    = var.codebuild_project_name
    Project = "hisaab"
  }
}

# ==========================================================================
# Canary orchestrator CodeBuild project
# ==========================================================================
# Runs between Build and Deploy (modules/pipeline/codepipeline.tf): pushes
# the candidate build to the single always-on canary instance
# (modules/compute) via SSM, ramps its ALB listener weight up in steps while
# polling the two canary CloudWatch alarms, and always resets weight back to
# 0 when done. Exports CANARY_PASSED, which gates whether the real Deploy
# stage (CodeDeploy, unchanged) ever runs.
#
# No artifacts.files in canary-buildspec.yml and no output_artifacts on this
# stage's pipeline action (codepipeline.tf) — this project produces nothing
# downstream, only the exported variable. Same shape already proven working
# by the Apply stage (modules/pipeline-infra), which also has no
# output_artifacts despite artifacts.type = "CODEPIPELINE".
#
# artifacts.type is still CODEPIPELINE (not NO_ARTIFACTS) because this
# project's *input* is a real CodePipeline artifact (build_output, for
# image_tag.txt and scripts/canary-deploy.sh) — CodeBuild's own role reads
# that directly from S3 (role-codebuild-canary's ArtifactBucketRead), same
# as every other CODEPIPELINE-type project in this pipeline.

resource "aws_codebuild_project" "canary_orchestrator" {
  name          = var.canary_orchestrator_project_name
  description   = "Ramps a small % of live traffic to the canary instance, alarm-gated, before the full-fleet CodeDeploy rollout runs"
  service_role  = var.role_codebuild_canary_arn
  build_timeout = 20 # 3 ramp steps x ~1 min each, plus SSM deploy + health-check polling, plus buffer

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "LISTENER_ARN"
      value = var.alb_listener_arn
    }

    environment_variable {
      name  = "BLUE_TG_ARN"
      value = var.blue_target_group_arn
    }

    environment_variable {
      name  = "CANARY_TG_ARN"
      value = var.canary_target_group_arn
    }

    environment_variable {
      name  = "CANARY_5XX_ALARM"
      value = var.canary_5xx_alarm_name
    }

    environment_variable {
      name  = "CANARY_LATENCY_ALARM"
      value = var.canary_latency_alarm_name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "canary-buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/${var.canary_orchestrator_project_name}"
    }
  }

  tags = {
    Name    = var.canary_orchestrator_project_name
    Project = "hisaab"
  }
}
