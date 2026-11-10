data "aws_caller_identity" "current" {}

locals {
  app_subnet_ids = [
    var.subnet_ids["sn-app-a"],
    var.subnet_ids["sn-app-b"],
  ]
  public_subnet_ids = [
    var.subnet_ids["sn-public-a"],
    var.subnet_ids["sn-public-b"],
  ]

  sg_app_id = var.sg_app_id
  sg_alb_id = var.sg_alb_id

  db_endpoint   = var.db_endpoint # "<host>:<port>"
  db_host       = split(":", local.db_endpoint)[0]
  db_port       = split(":", local.db_endpoint)[1]
  db_name       = var.db_name
  db_secret_arn = var.db_secret_arn
}

# ==========================================================================
# AMI lookup — Amazon Linux 2023, x86_64
# ==========================================================================

data "aws_ami" "al2023_x86_64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ==========================================================================
# Launch template lt-hisaab-api — §6.1
# ==========================================================================

resource "aws_launch_template" "hisaab_api" {
  name        = "lt-hisaab-api"
  description = "Hisaab API — image tag pinned per version, never latest (D6)"

  image_id      = data.aws_ami.al2023_x86_64.id
  instance_type = "t3.micro"

  iam_instance_profile {
    name = var.instance_profile_ec2_hisaab_name
  }

  vpc_security_group_ids = [local.sg_app_id]

  metadata_options {
    http_tokens = "required" # IMDSv2 required
    # The app container runs in Docker's default bridge network (docker run
    # -p 8080:8080, no --network host), which adds one network hop between
    # the container and the host's link-local IMDS endpoint. hop_limit=1
    # meant every IMDSv2 token request from inside the container was
    # silently dropped — confirmed the hard way: the AWS SDK's SNS calls
    # (the first AWS SDK calls ever made from inside the container; every
    # prior AWS interaction ran on the host via the CLI in start.sh) failed
    # with "Could not load credentials from any providers." Bumped to 2 to
    # cover that extra hop.
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  monitoring {
    enabled = true # Detailed monitoring
  }

  block_device_mappings {
    device_name = data.aws_ami.al2023_x86_64.root_device_name

    ebs {
      # Spec (§6.1) says 20GB, but the AL2023 AMI's own root snapshot grew
      # to 30GB since — AWS won't allow a volume smaller than the snapshot
      # it's created from, so 20GB now fails every launch outright. Bumped
      # to match the current AMI's actual floor.
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tpl", {
    region                = var.aws_region
    account_id            = data.aws_caller_identity.current.account_id
    ecr_repo_name         = var.ecr_repo_name
    image_tag             = var.image_tag
    db_secret_arn         = local.db_secret_arn
    db_host               = local.db_host
    db_port               = local.db_port
    db_name               = local.db_name
    cognito_user_pool_id  = var.cognito_user_pool_id
    cognito_app_client_id = var.cognito_app_client_id
    sqs_queue_url         = var.sqs_queue_url
    redis_host            = var.redis_host
    redis_port            = var.redis_port
  }))

  # Each apply that changes the image tag (or anything else here) creates a
  # new launch template version; making it the default is what CodeDeploy's
  # green_fleet_provisioning = COPY_AUTO_SCALING_GROUP picks up. Rollback is
  # pointing back at the previous version number.
  update_default_version = true

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name    = "hisaab-api"
      Project = "hisaab"
    }
  }

  tags = {
    Name    = "lt-hisaab-api"
    Project = "hisaab"
  }
}

# ==========================================================================
# CodeDeploy permission — deferred from modules/security
# ==========================================================================
# ec2:RunInstances on this specific launch template couldn't be scoped in
# modules/security because the template's AWS-generated ARN didn't exist
# yet. Attached here, now that it does — same deferred-permission pattern
# modules/data uses for the RDS secret-read grant on role-ec2-hisaab.
# Distinct from (and in addition to) the ec2:DescribeLaunchTemplate* grant
# already on role-codedeploy: reading a launch template and being
# authorized to launch instances from it via CreateAutoScalingGroup are two
# separate IAM checks.
#
# ec2:RunInstances via a launch template is a multi-resource IAM check —
# AWS evaluates the launch template, the AMI, the resulting instance, and
# its network resources (ENI/subnet/security-group/volume) together in one
# authorization decision, not just the launch template alone (confirmed
# the hard way: scoping this to only the launch template ARN reproduced
# the exact same generic error as having no custom policy at all). The AMI
# is looked up dynamically (data.aws_ami, most_recent = true) and changes
# over time, so it's wildcarded rather than pinned to today's specific ID.
#
# Tag propagation is also enabled on the ASG below (propagate_at_launch =
# true), which needs its own separate ec2:CreateTags grant — CreateTags is
# not part of RunInstances' own authorization at all.

resource "aws_iam_role_policy" "codedeploy_run_instances" {
  name = "role-codedeploy-run-instances"
  role = var.role_codedeploy_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "UseLaunchTemplate"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          aws_launch_template.hisaab_api.arn,
          "arn:aws:ec2:${var.aws_region}::image/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:subnet/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/*",
        ]
      },
      {
        Sid      = "TagOnLaunch"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "RunInstances"
          }
        }
      },
    ]
  })
}

# ==========================================================================
# Autoscaling group — §6.2
# ==========================================================================
# One persistent ASG, spanning both AZs. CodeDeploy's blue/green mechanism
# for the EC2/"Server" compute platform (as opposed to ECS/Lambda) works by
# copying this ASG into a temporary replacement fleet per deployment
# (green_fleet_provisioning_option = COPY_AUTO_SCALING_GROUP in
# modules/pipeline), then terminating it after cutover — there's no second,
# permanently-named "green" ASG to create here. An earlier version of this
# module had one; it was never touched by any deployment and was removed
# once that was confirmed against AWS's own API docs.
#
# This resource only ever serves as the seed for CodeDeploy's very first
# copy. Confirmed the hard way: COPY_AUTO_SCALING_GROUP deletes the ASG it
# copies from once its replacement takes over, entirely outside Terraform's
# knowledge — so every successful deployment leaves this resource dangling
# in state pointing at nothing. Any later `terraform apply` (for a
# completely unrelated change elsewhere) then sees it "missing" and
# recreates it fresh — and since it used to carry a static
# target_group_arns attachment, that recreation immediately put stale,
# whatever-was-in-the-launch-template-at-that-moment instances back in
# front of live traffic, alongside whatever ASG CodeDeploy actually
# considers current. No target group attachment here at all avoids that:
# if this resource gets recreated, it's inert until CodeDeploy's next
# deployment does its own copy-and-attach. ignore_changes on capacity
# covers the same drift for min/max/desired, which the CPU-based scaling
# policy (and manual intervention, when cleaning up stray capacity) can
# legitimately move out from under Terraform's config value.
#
# count, not an unconditional resource: "inert until the next deployment"
# still means every plan after the very first successful deployment wants
# to recreate this — harmless to live traffic, but real wasted cost (two
# idle EC2 instances) on every single apply, forever, and genuinely unsafe
# once applies aren't being hand-reviewed line-by-line (see the
# self-mutating pipeline this was built for). var.asg_bootstrapped defaults
# to true — already-bootstrapped, matching this environment's actual
# state — which fully stops Terraform from ever proposing this again.

resource "aws_autoscaling_group" "hisaab" {
  count               = var.asg_bootstrapped ? 0 : 1
  name                = "asg-hisaab-blue"
  vpc_zone_identifier = local.app_subnet_ids

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  health_check_type         = "ELB" # Not EC2 — a dead container inside a running instance must fail this (D5)
  health_check_grace_period = 180

  launch_template {
    id      = aws_launch_template.hisaab_api.id
    version = "$Latest"
  }

  termination_policies = ["Default"] # Balances across AZs before other criteria

  tag {
    key                 = "Name"
    value               = "asg-hisaab-blue"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "hisaab"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [min_size, max_size, desired_capacity]
  }
}

# Deviates from spec §6.2, which calls for ALBRequestCountPerTarget — that
# metric is structurally incompatible with CodeDeploy's blue/green
# COPY_AUTO_SCALING_GROUP mechanism for the EC2/Server platform. CodeDeploy
# always creates the copied ("green") ASG before attaching it to a target
# group, but ALBRequestCountPerTarget requires the ASG to already be
# attached to the specific target group it references — so replicating
# this policy onto the copy fails with a real, correctly-reported
# ValidationError ("Target group not attached to the Auto Scaling group"),
# before CodeDeploy ever gets to the attach step. Confirmed via CloudTrail
# (see docs/codedeploy-troubleshooting.md) — every deployment attempt
# failed at PutScalingPolicy, not at anything IAM-related. Average CPU
# utilization has no such dependency and keeps blue/green deployments
# (the part of D-whatever that actually matters more) intact.
resource "aws_autoscaling_policy" "cpu_utilization" {
  count                  = var.asg_bootstrapped ? 0 : 1
  name                   = "asg-hisaab-blue-cpu-utilization"
  autoscaling_group_name = aws_autoscaling_group.hisaab[0].name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70
  }
}

# ==========================================================================
# Canary ASG
# ==========================================================================
# One always-on instance, fixed at size 1 — unlike asg-hisaab-blue above,
# this one is genuinely permanent and Terraform owns it outright: nothing
# else (CodeDeploy, an autoscaling policy) ever deletes or recreates it out
# from under Terraform, so there's no bootstrapped-count-gate or capacity
# ignore_changes needed here.
#
# target_group_arns is set directly (unlike blue's ASG, which deliberately
# has none) — this is exactly what makes it safe here: this ASG's only job
# is sitting in tg-hisaab-canary, and it's never touched by
# COPY_AUTO_SCALING_GROUP, so there's no risk of a stale recreate silently
# joining live full-weight traffic the way blue's would.
#
# launch_template version = "$Latest" only determines what a *fresh*
# replacement instance cold-starts with (e.g. if this ASG's health check
# ever fails one) — it does not retroactively touch the currently-running
# instance. The actual candidate build under test is pushed to whichever
# instance is running via SSM Run Command by the canary orchestrator
# (modules/pipeline), independent of what Terraform last applied.
resource "aws_autoscaling_group" "canary" {
  name                = "asg-hisaab-canary"
  vpc_zone_identifier = local.app_subnet_ids

  min_size         = 1
  max_size         = 1
  desired_capacity = 1

  health_check_type         = "ELB"
  health_check_grace_period = 180

  launch_template {
    id      = aws_launch_template.hisaab_api.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.canary.arn]

  termination_policies = ["Default"]

  tag {
    key                 = "Name"
    value               = "hisaab-api-canary"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "canary"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "hisaab"
    propagate_at_launch = true
  }
}
