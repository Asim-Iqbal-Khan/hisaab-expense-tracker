# ==========================================================================
# Deployment packages
# ==========================================================================
# Unlike the app container (deployed via CodeDeploy/ECR, phase 8),
# buildspec.yml never touches these Lambdas — there is no other deployment
# path for their code. Terraform is the only thing that ever pushes a new
# archive_file build to AWS, so it must NOT ignore_changes on
# filename/source_code_hash: an earlier version of this file did (by
# analogy with the ALB listener's default_action, before that analogy was
# itself found to be wrong and reverted — see CLAUDE.md), and it silently
# pinned both functions to their original placeholder-stub code forever,
# since nothing else was ever going to deploy the real thing.

data "archive_file" "post_confirmation" {
  type        = "zip"
  source_dir  = "${path.module}/src/post_confirmation"
  output_path = "${path.module}/build/post_confirmation.zip"
}

data "archive_file" "reminder_dispatcher" {
  type        = "zip"
  source_dir  = "${path.module}/src/reminder_dispatcher"
  output_path = "${path.module}/build/reminder_dispatcher.zip"
}

data "archive_file" "email_sender" {
  type        = "zip"
  source_dir  = "${path.module}/src/email_sender"
  output_path = "${path.module}/build/email_sender.zip"
}

# ==========================================================================
# fn-post-confirmation — §9.1, §10.1
# ==========================================================================

resource "aws_lambda_function" "post_confirmation" {
  function_name = var.post_confirmation_function_name
  role          = var.role_lambda_postconfirm_arn

  filename         = data.archive_file.post_confirmation.output_path
  source_code_hash = data.archive_file.post_confirmation.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]

  memory_size = 128
  timeout     = 30

  vpc_config {
    subnet_ids         = local.app_subnet_ids
    security_group_ids = [local.sg_lambda_id]
  }

  environment {
    variables = {
      DB_HOST         = local.db_host
      DB_PORT         = local.db_port
      DB_NAME         = local.db_name
      DB_SECRET_ARN   = local.db_secret_arn
      AWS_REGION_NAME = var.aws_region
    }
  }

  tags = {
    Name    = "fn-post-confirmation"
    Project = "hisaab"
  }
}

resource "aws_lambda_permission" "cognito_invoke" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.post_confirmation.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = local.user_pool_arn
}

# ==========================================================================
# fn-reminder-dispatcher — §10.3
# ==========================================================================

resource "aws_lambda_function" "reminder_dispatcher" {
  function_name = var.reminder_dispatcher_function_name
  role          = var.role_lambda_reminder_arn

  filename         = data.archive_file.reminder_dispatcher.output_path
  source_code_hash = data.archive_file.reminder_dispatcher.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]

  memory_size = 128
  timeout     = 60 # Queries balances for potentially many users; postconfirm only handles one

  vpc_config {
    subnet_ids         = local.app_subnet_ids
    security_group_ids = [local.sg_lambda_id]
  }

  environment {
    variables = {
      # Points at the read replica, not the primary — this is the one
      # read path in the app where async replication lag is a non-issue
      # rather than a real risk (see modules/data's note next to the
      # replica resource).
      DB_HOST         = local.db_replica_host
      DB_PORT         = local.db_replica_port
      DB_NAME         = local.db_name
      DB_SECRET_ARN   = local.db_secret_arn
      SQS_QUEUE_URL   = aws_sqs_queue.notifications.url
      AWS_REGION_NAME = var.aws_region
    }
  }

  tags = {
    Name    = "fn-reminder-dispatcher"
    Project = "hisaab"
  }
}

# ==========================================================================
# fn-email-sender — §10.1
# ==========================================================================
# Producers (the API, fn-reminder-dispatcher) resolve the recipient email
# themselves before enqueueing, so this Lambda's only job is "pop a
# message, call SES" — no DB access, no VPC placement needed at all, unlike
# its siblings. Skipping VPC placement also avoids the ENI cold-start cost.

resource "aws_lambda_function" "email_sender" {
  function_name = var.email_sender_function_name
  role          = var.role_lambda_email_sender_arn

  filename         = data.archive_file.email_sender.output_path
  source_code_hash = data.archive_file.email_sender.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]

  memory_size = 128
  timeout     = 30

  environment {
    variables = {
      SES_FROM_ADDRESS = "notifications@${aws_ses_domain_identity.hisaab.domain}"
      AWS_REGION_NAME  = var.aws_region
    }
  }

  tags = {
    Name    = "fn-email-sender"
    Project = "hisaab"
  }
}

resource "aws_lambda_event_source_mapping" "email_sender_sqs" {
  event_source_arn = aws_sqs_queue.notifications.arn
  function_name    = aws_lambda_function.email_sender.arn
  batch_size       = 10

  # Partial-batch-failure handling: the handler returns batchItemFailures
  # for only the messages that actually failed, so a single bad message
  # doesn't cause the whole batch (including already-sent emails) to be
  # redelivered.
  function_response_types = ["ReportBatchItemFailures"]
}
