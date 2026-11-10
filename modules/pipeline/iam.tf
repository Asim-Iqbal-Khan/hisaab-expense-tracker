# ==========================================================================
# Deferred from modules/security (phase 2)
# ==========================================================================
# codestar-connections:UseConnection couldn't be scoped in phase 2 because
# the connection's AWS-generated ID didn't exist yet. Attached here, now
# that it does — same deferred-permission pattern used for the DB secret
# read grants in modules/data.

resource "aws_iam_role_policy" "codepipeline_codestar" {
  name = "role-codepipeline-codestar-connection"
  role = var.role_codepipeline_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UseGithubConnection"
        Effect   = "Allow"
        Action   = "codestar-connections:UseConnection"
        Resource = var.codestar_connection_arn
      },
    ]
  })
}

# Same deferred pattern, for the new Canary stage's CodeBuild project —
# matches modules/pipeline-infra's codepipeline_infra_build grant exactly.

resource "aws_iam_role_policy" "codepipeline_canary_build" {
  name = "role-codepipeline-canary-build"
  role = var.role_codepipeline_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeCanaryBuild"
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
        ]
        Resource = aws_codebuild_project.canary_orchestrator.arn
      },
    ]
  })
}
