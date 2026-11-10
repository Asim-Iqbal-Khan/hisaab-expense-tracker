data "aws_caller_identity" "current" {}

locals {
  role_codebuild_arn    = var.role_codebuild_arn
  role_codedeploy_arn   = var.role_codedeploy_arn
  role_codepipeline_arn = var.role_codepipeline_arn

  # CodeDeploy dynamically copies this ASG into a temporary replacement
  # fleet per deployment (green_fleet_provisioning_option =
  # COPY_AUTO_SCALING_GROUP below) — there's no separate, permanent
  # "green" ASG or target group to reference; modules/compute only builds
  # one of each now.
  live_asg_name = var.asg_name
  tg_name       = var.target_group_name
}
