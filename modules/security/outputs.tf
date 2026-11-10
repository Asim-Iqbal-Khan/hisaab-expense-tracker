output "sg_alb_id" {
  description = "ID of sg-alb"
  value       = aws_security_group.alb.id
}

output "sg_app_id" {
  description = "ID of sg-app"
  value       = aws_security_group.app.id
}

output "sg_data_id" {
  description = "ID of sg-data"
  value       = aws_security_group.data.id
}

output "sg_lambda_id" {
  description = "ID of sg-lambda"
  value       = aws_security_group.lambda.id
}

output "sg_cache_id" {
  description = "ID of sg-cache"
  value       = aws_security_group.cache.id
}

output "role_ec2_hisaab_arn" {
  description = "ARN of role-ec2-hisaab"
  value       = aws_iam_role.ec2_hisaab.arn
}

output "role_ec2_hisaab_name" {
  description = "Name of role-ec2-hisaab (for modules/data to attach the DB secret read permission)"
  value       = aws_iam_role.ec2_hisaab.name
}

output "instance_profile_ec2_hisaab_name" {
  description = "Name of the EC2 instance profile for role-ec2-hisaab"
  value       = aws_iam_instance_profile.ec2_hisaab.name
}

output "role_lambda_postconfirm_arn" {
  description = "ARN of role-lambda-postconfirm"
  value       = aws_iam_role.lambda_postconfirm.arn
}

output "role_lambda_postconfirm_name" {
  description = "Name of role-lambda-postconfirm (for modules/data to attach the DB secret read permission)"
  value       = aws_iam_role.lambda_postconfirm.name
}

output "role_lambda_reminder_arn" {
  description = "ARN of role-lambda-reminder"
  value       = aws_iam_role.lambda_reminder.arn
}

output "role_lambda_reminder_name" {
  description = "Name of role-lambda-reminder (for modules/data to attach the DB secret read permission)"
  value       = aws_iam_role.lambda_reminder.name
}

output "role_lambda_email_sender_arn" {
  description = "ARN of role-lambda-email-sender"
  value       = aws_iam_role.lambda_email_sender.arn
}

output "role_codebuild_arn" {
  description = "ARN of role-codebuild"
  value       = aws_iam_role.codebuild.arn
}

output "role_codebuild_name" {
  description = "Name of role-codebuild — used by modules/delivery to attach a CloudFront invalidation permission once the distribution ARN is known"
  value       = aws_iam_role.codebuild.name
}

output "role_codedeploy_name" {
  description = "Name of role-codedeploy — used by modules/compute to attach an ec2:RunInstances-on-launch-template permission once the launch template's AWS-generated ARN is known"
  value       = aws_iam_role.codedeploy.name
}

output "role_codebuild_canary_arn" {
  description = "ARN of role-codebuild-canary"
  value       = aws_iam_role.codebuild_canary.arn
}

output "role_codebuild_canary_name" {
  description = "Name of role-codebuild-canary — used by modules/compute to attach an elasticloadbalancing:ModifyListener permission once the listener's AWS-generated ARN is known"
  value       = aws_iam_role.codebuild_canary.name
}

output "role_codedeploy_arn" {
  description = "ARN of role-codedeploy"
  value       = aws_iam_role.codedeploy.arn
}

output "role_codepipeline_arn" {
  description = "ARN of role-codepipeline"
  value       = aws_iam_role.codepipeline.arn
}

output "role_codepipeline_name" {
  description = "Name of role-codepipeline (for modules/pipeline to attach the CodeStar connection permission)"
  value       = aws_iam_role.codepipeline.name
}
