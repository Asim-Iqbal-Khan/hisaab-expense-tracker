# ==========================================================================
# ECR repository — §12
# ==========================================================================
# IMMUTABLE tags enforce D6 (image tags are the git commit SHA, never
# "latest") at the AWS API level — a push attempting to reuse an existing
# tag is rejected outright, not just discouraged by convention.

resource "aws_ecr_repository" "hisaab_api" {
  name                 = var.ecr_repo_name
  image_tag_mutability = "IMMUTABLE"
  # Pre-production environment; don't let leftover images block a future
  # teardown — same reasoning as force_destroy on the other pre-prod
  # buckets. Confirmed the hard way: a real `terraform destroy` got stuck
  # on this repo still holding 16 images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = var.ecr_repo_name
    Project = "hisaab"
  }
}
