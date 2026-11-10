# ==========================================================================
# pipe-hisaab-app — §12.1, extended with a self-mutating infra plan/apply
# ==========================================================================
# One pipeline, not two, per an explicit later decision to fold
# pipe-hisaab-infra's Plan/Approve/Apply stages in here rather than run
# them as a separate pipeline. The name stays pipe-hisaab-app (a rename
# would force-replace the whole resource, losing execution history, for a
# cosmetic-only reason) even though it's no longer just the app anymore.
#
# Plan always runs, on every push — but Approve and Apply skip themselves
# automatically when terraform plan finds nothing to do, via each stage's
# before_entry condition checking a variable the Plan stage exports. This
# is deliberate: an app-code-only commit (the overwhelming majority of
# pushes) still deploys fast and unattended, exactly like before this
# merge — it only waits on a human when there's an actual infra diff to
# review. Uses terraform plan's own -detailed-exitcode (0 = no changes,
# 2 = changes) as the source of truth for "is there anything to do" rather
# than approximating it from which files changed — a real diff is a more
# reliable signal than a file-path guess (e.g. a modules/ edit that
# happens not to affect envs/prod's specific resources).
#
# The VariableCheck rule condition (Approve/Apply below) is confirmed
# working against a real pipeline run — an infra-touching push correctly
# triggered Approve and skip logic as designed.
#
# The Canary stage sits between Build and Deploy: it runs the same
# CodeBuild project standalone-tested via manual start-build overrides
# (SSM deploy to the always-on canary instance, alarm-gated weight ramp,
# always resets to 0% when done) — see modules/compute/alb.tf for
# tg-hisaab-canary and the canary alarms, modules/compute/main.tf for the
# canary ASG. Deploy's own before_entry gate reuses the exact same
# VariableCheck shape, keyed off CanaryVars.CANARY_PASSED instead of
# PlanVars.PLAN_HAS_CHANGES — confirmed via the same standalone builds
# (CANARY_PASSED=false on a genuine alarm breach, =true on a clean run),
# though the gate's behavior *inside a live pipeline run* specifically
# hasn't been observed yet — watch the first real push closely.

resource "aws_codepipeline" "hisaab_app" {
  name          = "pipe-hisaab-app"
  role_arn      = local.role_codepipeline_arn
  pipeline_type = "V2" # before_entry/condition (below) needs V2, same as the trigger feature pipe-hisaab-infra already used

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.pipeline_artifacts.bucket
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = var.codestar_connection_arn
        FullRepositoryId = "${var.github_org}/${var.github_repo}"
        BranchName       = var.github_branch
      }
    }
  }

  stage {
    name = "Plan"

    action {
      name             = "Plan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["plan_output"]
      namespace        = "PlanVars"

      configuration = {
        ProjectName = var.infra_plan_project_name
      }
    }
  }

  stage {
    name = "Approve"

    before_entry {
      condition {
        result = "SKIP"

        rule {
          name = "InfraChanged"

          rule_type_id {
            category = "Rule"
            owner    = "AWS"
            provider = "VariableCheck"
            version  = "1"
          }

          configuration = {
            Variable = "#{PlanVars.PLAN_HAS_CHANGES}"
            Value    = "true"
            Operator = "EQ"
          }
        }
      }
    }

    action {
      name     = "Approve"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
    }
  }

  stage {
    name = "Apply"

    before_entry {
      condition {
        result = "SKIP"

        rule {
          name = "InfraChanged"

          rule_type_id {
            category = "Rule"
            owner    = "AWS"
            provider = "VariableCheck"
            version  = "1"
          }

          configuration = {
            Variable = "#{PlanVars.PLAN_HAS_CHANGES}"
            Value    = "true"
            Operator = "EQ"
          }
        }
      }
    }

    action {
      name     = "Apply"
      category = "Build"
      owner    = "AWS"
      provider = "CodeBuild"
      version  = "1"
      # Needs both: the source checkout (matching exactly what was
      # planned) and the saved plan file from the Plan stage above.
      # PrimarySource picks which becomes the normal working directory —
      # the plan artifact is still reachable, just under
      # $CODEBUILD_SRC_DIR_plan_output (see infra-apply-buildspec.yml).
      input_artifacts = ["source_output", "plan_output"]

      configuration = {
        ProjectName   = var.infra_apply_project_name
        PrimarySource = "source_output"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.hisaab_api.name
      }
    }
  }

  stage {
    name = "Canary"

    action {
      name            = "Canary"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["build_output"]
      namespace       = "CanaryVars"

      configuration = {
        ProjectName = aws_codebuild_project.canary_orchestrator.name
      }
    }
  }

  stage {
    name = "Deploy"

    # CodeDeploy's full-fleet cutover only runs once the canary orchestrator
    # has proven the build against a real (small) slice of live traffic —
    # same VariableCheck gating shape as Approve/Apply above, just keyed off
    # CanaryVars.CANARY_PASSED instead of PlanVars.PLAN_HAS_CHANGES. If the
    # Canary stage's alarms ever breach mid-ramp, this SKIPs and the full
    # fleet never sees the bad build.
    before_entry {
      condition {
        result = "SKIP"

        rule {
          name = "CanaryPassed"

          rule_type_id {
            category = "Rule"
            owner    = "AWS"
            provider = "VariableCheck"
            version  = "1"
          }

          configuration = {
            Variable = "#{CanaryVars.CANARY_PASSED}"
            Value    = "true"
            Operator = "EQ"
          }
        }
      }
    }

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ApplicationName     = aws_codedeploy_app.hisaab_api.name
        DeploymentGroupName = aws_codedeploy_deployment_group.hisaab_api.deployment_group_name
      }
    }
  }

  tags = {
    Name    = "pipe-hisaab-app"
    Project = "hisaab"
  }
}
