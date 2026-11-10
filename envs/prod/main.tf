# Dependency order: network, security, data, identity, compute, messaging,
# delivery, pipeline. Terraform's module graph enforces this automatically
# via the module.x.y references below; this ordering is written to match
# it for readability, not because Terraform needs the blocks in this order.

module "network" {
  source = "../../modules/network"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  aws_region              = var.aws_region
  vpc_cidr                = var.vpc_cidr
  hosted_zone_id          = var.hosted_zone_id
  parent_domain           = var.parent_domain
  flow_log_retention_days = var.flow_log_retention_days
}

module "security" {
  source = "../../modules/security"

  aws_region                     = var.aws_region
  vpc_id                         = module.network.vpc_id
  ecr_repo_name                  = var.ecr_repo_name
  sqs_queue_name                 = var.sqs_queue_name
  codebuild_project_name         = var.codebuild_project_name
  codedeploy_app_name            = var.codedeploy_app_name
  profile_pics_bucket_name       = var.profile_pics_bucket_name
  pipeline_artifacts_bucket_name = var.pipeline_artifacts_bucket_name
  frontend_bucket_name           = var.frontend_bucket_name
}

module "data" {
  source = "../../modules/data"

  aws_region                   = var.aws_region
  subnet_ids                   = module.network.subnet_ids
  sg_data_id                   = module.security.sg_data_id
  role_ec2_hisaab_name         = module.security.role_ec2_hisaab_name
  role_lambda_postconfirm_name = module.security.role_lambda_postconfirm_name
  role_lambda_reminder_name    = module.security.role_lambda_reminder_name
  db_name                      = var.db_name
  db_master_username           = var.db_master_username
  db_master_password           = var.db_master_password
  db_master_password_version   = var.db_master_password_version
  rds_deletion_protection      = var.rds_deletion_protection
}

module "identity" {
  source = "../../modules/identity"

  aws_region                      = var.aws_region
  post_confirmation_function_name = var.post_confirmation_function_name
}

module "cache" {
  source = "../../modules/cache"

  aws_region  = var.aws_region
  subnet_ids  = module.network.subnet_ids
  sg_cache_id = module.security.sg_cache_id
}

module "compute" {
  source = "../../modules/compute"

  aws_region                       = var.aws_region
  subnet_ids                       = module.network.subnet_ids
  vpc_id                           = module.network.vpc_id
  acm_certificate_alb_arn          = module.network.acm_certificate_alb_arn
  hosted_zone_id                   = module.network.hosted_zone_id
  sg_app_id                        = module.security.sg_app_id
  sg_alb_id                        = module.security.sg_alb_id
  instance_profile_ec2_hisaab_name = module.security.instance_profile_ec2_hisaab_name
  db_endpoint                      = module.data.db_endpoint
  db_name                          = module.data.db_name
  db_secret_arn                    = module.data.db_secret_arn
  cognito_user_pool_id             = module.identity.user_pool_id
  cognito_app_client_id            = module.identity.app_client_id
  sqs_queue_url                    = module.messaging.sqs_queue_url
  redis_host                       = module.cache.redis_endpoint
  redis_port                       = module.cache.redis_port
  role_codedeploy_name             = module.security.role_codedeploy_name
  role_codebuild_canary_name       = module.security.role_codebuild_canary_name
  ecr_repo_name                    = var.ecr_repo_name
  parent_domain                    = var.parent_domain
  image_tag                        = var.image_tag
  asg_min_size                     = var.asg_min_size
  asg_desired_capacity             = var.asg_desired_capacity
  asg_max_size                     = var.asg_max_size
  asg_bootstrapped                 = var.asg_bootstrapped
  profile_pics_bucket_name         = var.profile_pics_bucket_name
  alb_logs_bucket_name             = var.alb_logs_bucket_name
  elb_service_account_id           = var.elb_service_account_id
}

module "messaging" {
  source = "../../modules/messaging"

  aws_region                        = var.aws_region
  subnet_ids                        = module.network.subnet_ids
  sg_lambda_id                      = module.security.sg_lambda_id
  db_endpoint                       = module.data.db_endpoint
  db_replica_endpoint               = module.data.db_replica_endpoint
  db_name                           = module.data.db_name
  db_secret_arn                     = module.data.db_secret_arn
  user_pool_arn                     = module.identity.user_pool_arn
  role_lambda_postconfirm_arn       = module.security.role_lambda_postconfirm_arn
  role_lambda_reminder_arn          = module.security.role_lambda_reminder_arn
  role_lambda_email_sender_arn      = module.security.role_lambda_email_sender_arn
  sqs_queue_name                    = var.sqs_queue_name
  hosted_zone_id                    = module.network.hosted_zone_id
  parent_domain                     = var.parent_domain
  post_confirmation_function_name   = var.post_confirmation_function_name
  reminder_dispatcher_function_name = var.reminder_dispatcher_function_name
  reminder_schedule_expression      = var.reminder_schedule_expression
}

module "delivery" {
  source = "../../modules/delivery"

  aws_region                     = var.aws_region
  acm_certificate_cloudfront_arn = module.network.acm_certificate_cloudfront_arn
  hosted_zone_id                 = module.network.hosted_zone_id
  frontend_bucket_name           = var.frontend_bucket_name
  parent_domain                  = var.parent_domain
  alb_origin_domain              = module.compute.app_domain
  role_codebuild_name            = module.security.role_codebuild_name
}

module "pipeline" {
  source = "../../modules/pipeline"

  aws_region                     = var.aws_region
  codestar_connection_arn        = var.codestar_connection_arn
  role_codebuild_arn             = module.security.role_codebuild_arn
  role_codedeploy_arn            = module.security.role_codedeploy_arn
  role_codepipeline_arn          = module.security.role_codepipeline_arn
  role_codepipeline_name         = module.security.role_codepipeline_name
  asg_name                       = module.compute.asg_name
  target_group_name              = module.compute.target_group_name
  github_org                     = var.github_org
  github_repo                    = var.github_repo
  github_branch                  = var.github_branch
  ecr_repo_name                  = var.ecr_repo_name
  codebuild_project_name         = var.codebuild_project_name
  codedeploy_app_name            = var.codedeploy_app_name
  pipeline_artifacts_bucket_name = var.pipeline_artifacts_bucket_name
  alb_5xx_alarm_name             = var.alb_5xx_alarm_name
  frontend_bucket_name           = module.delivery.frontend_bucket_name
  cloudfront_distribution_id     = module.delivery.cloudfront_distribution_id
  cognito_app_client_id          = module.identity.app_client_id
  infra_plan_project_name        = module.pipeline_infra.infra_plan_project_name
  infra_apply_project_name       = module.pipeline_infra.infra_apply_project_name
  role_codebuild_canary_arn      = module.security.role_codebuild_canary_arn
  alb_listener_arn               = module.compute.alb_listener_https_arn
  blue_target_group_arn          = module.compute.target_group_arn
  canary_target_group_arn        = module.compute.canary_target_group_arn
  canary_5xx_alarm_name          = module.compute.canary_5xx_alarm_name
  canary_latency_alarm_name      = module.compute.canary_latency_alarm_name
}

module "pipeline_infra" {
  source = "../../modules/pipeline-infra"

  aws_region                    = var.aws_region
  role_codepipeline_name        = module.security.role_codepipeline_name
  role_terraform_arn            = var.role_terraform_arn
  db_master_password_secret_arn = module.data.db_secret_arn
}
