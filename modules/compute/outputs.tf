output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.hisaab.dns_name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.hisaab.arn
}

output "alb_listener_https_arn" {
  description = "ARN of the HTTPS listener — consumed by modules/pipeline's canary orchestrator, which calls ModifyListener directly to ramp weights between tg-hisaab-blue and tg-hisaab-canary."
  value       = aws_lb_listener.https.arn
}

output "launch_template_id" {
  description = "Launch template ID"
  value       = aws_launch_template.hisaab_api.id
}

output "launch_template_latest_version" {
  description = "Latest launch template version"
  value       = aws_launch_template.hisaab_api.latest_version
}

output "asg_name" {
  description = "Name CodeDeploy's deployment group registers with. A literal string, not read off the resource itself — that resource only exists pre-bootstrap (see var.asg_bootstrapped), but this name is what the seed ASG was always hardcoded to anyway, so the value doesn't change either way."
  value       = "asg-hisaab-blue"
}

output "target_group_arn" {
  description = "ARN of the persistent target group"
  value       = aws_lb_target_group.hisaab.arn
}

output "target_group_name" {
  description = "Name of the persistent target group"
  value       = aws_lb_target_group.hisaab.name
}

output "app_domain" {
  description = "Public API domain name"
  value       = "app.hisaab.${var.parent_domain}"
}

output "canary_target_group_arn" {
  description = "ARN of tg-hisaab-canary"
  value       = aws_lb_target_group.canary.arn
}

output "canary_asg_name" {
  description = "Name of the always-on canary ASG (asg-hisaab-canary)"
  value       = aws_autoscaling_group.canary.name
}

output "canary_5xx_alarm_name" {
  description = "CloudWatch alarm name the canary orchestrator polls for 5xx breaches during a weight ramp"
  value       = aws_cloudwatch_metric_alarm.canary_5xx.alarm_name
}

output "canary_latency_alarm_name" {
  description = "CloudWatch alarm name the canary orchestrator polls for latency breaches during a weight ramp"
  value       = aws_cloudwatch_metric_alarm.canary_latency.alarm_name
}
