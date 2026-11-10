# ==========================================================================
# CodeStar connection — §12.1
# ==========================================================================
# The connection itself lives in its own isolated Terraform state
# (../../github-connection), not here — its GitHub OAuth authorization is a
# one-time, human-in-the-console step (AWS gives no API/Terraform way to
# complete it), so keeping it out of envs/prod means a `terraform destroy` +
# `terraform apply` cycle on the main environment never needs that manual
# re-authorization again. This module just consumes the ARN.

data "aws_codestarconnections_connection" "github" {
  arn = var.codestar_connection_arn
}
