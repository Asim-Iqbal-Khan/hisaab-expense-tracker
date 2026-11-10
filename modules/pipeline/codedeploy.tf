# ==========================================================================
# CodeDeploy application + deployment group — §12.1
# ==========================================================================

resource "aws_codedeploy_app" "hisaab_api" {
  name             = var.codedeploy_app_name
  compute_platform = "Server" # EC2/on-premises platform, required for ASG blue/green

  tags = {
    Name    = var.codedeploy_app_name
    Project = "hisaab"
  }
}

resource "aws_codedeploy_deployment_group" "hisaab_api" {
  app_name              = aws_codedeploy_app.hisaab_api.name
  deployment_group_name = "dg-hisaab-api"
  service_role_arn      = local.role_codedeploy_arn

  # Only asg-hisaab-blue is registered here — CodeDeploy copies it into a
  # temporary replacement fleet per deployment (green_fleet_provisioning
  # below), it doesn't reuse the pre-existing asg-hisaab-green. That
  # replacement ASG becomes the new "current" one CodeDeploy tracks after a
  # successful deployment, entirely outside Terraform's knowledge — so
  # without ignore_changes here, every later `terraform apply` reverts this
  # back to the static seed name, undoing CodeDeploy's own hand-off and
  # pointing the next deployment at a stale (possibly zero-capacity)
  # reference. Confirmed the hard way: a `plan` for an unrelated CloudFront
  # fix wanted to do exactly this.
  autoscaling_groups = [local.live_asg_name]

  lifecycle {
    ignore_changes = [autoscaling_groups]
  }

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    green_fleet_provisioning_option {
      action = "COPY_AUTO_SCALING_GROUP"
    }

    terminate_blue_instances_on_deployment_success {
      action = "TERMINATE"
      # Temporarily reduced from 10 for faster debug iteration during
      # active development (every push means a full deploy cycle, and the
      # old fleet sitting around for 10 minutes each time was slowing down
      # diagnosis). Bump this back up once things stabilize — it exists as
      # a real rollback safety window, not just cleanup delay.
      termination_wait_time_in_minutes = 2
    }
  }

  # target_group_pair_info (prod_traffic_route + two target groups) is
  # ECS/Lambda-only per AWS's own API docs — confirmed the hard way via a
  # real InvalidLoadBalancerInfoException on first apply. The EC2/"Server"
  # compute platform used here shifts traffic by registering/deregistering
  # instances within a single target group; target_group_info is the
  # correct field.
  load_balancer_info {
    target_group_info {
      name = local.tg_name
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  # Disabled until modules/observability (phase 10) actually creates
  # alb_5xx_alarm_name — confirmed the hard way that referencing a
  # non-existent alarm here doesn't fail harmlessly as originally assumed
  # (see var.alb_5xx_alarm_name's description): it breaks blue/green
  # deployments outright. CodeDeploy creates the green ASG successfully
  # (confirmed via CloudTrail) but never proceeds to attach it to the
  # target group, reporting a generic, misleading AutoScaling error
  # instead of anything mentioning the alarm. Re-enable once phase 10
  # exists.
  alarm_configuration {
    enabled = false
    alarms  = [var.alb_5xx_alarm_name]
  }

  tags = {
    Name    = "dg-hisaab-api"
    Project = "hisaab"
  }
}
