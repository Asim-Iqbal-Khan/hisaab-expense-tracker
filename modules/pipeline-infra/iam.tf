# ==========================================================================
# Deferred from modules/security (phase 2)
# ==========================================================================
# role-codepipeline already exists, but couldn't be granted permission to
# start these two CodeBuild projects until their AWS-generated ARNs
# existed — same deferred-permission pattern used throughout this repo
# (modules/data's DB secret grants, modules/pipeline's own codestar
# permission).

resource "aws_iam_role_policy" "codepipeline_infra_build" {
  name = "role-codepipeline-infra-build"
  role = var.role_codepipeline_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeInfraBuild"
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
        ]
        Resource = [
          aws_codebuild_project.infra_plan.arn,
          aws_codebuild_project.infra_apply.arn,
        ]
      },
    ]
  })
}
