# ==========================================================================
# CodeStar (GitHub) connection — isolated from envs/prod on purpose
# ==========================================================================
# Terraform can only create this in PENDING status. AWS requires a human to
# complete the GitHub OAuth handshake in the console (CodePipeline > Settings
# > Connections > "Update pending connection") before this connection can
# actually be used as a pipeline source — there is no API or Terraform-
# managed way to finish this step. Already done once for the existing
# connection this module imports; keeping it in its own state means that
# authorization survives any future destroy/rebuild of envs/prod.

resource "aws_codestarconnections_connection" "github" {
  name          = var.connection_name
  provider_type = "GitHub"

  tags = {
    Name    = var.connection_name
    Project = "hisaab"
  }
}
