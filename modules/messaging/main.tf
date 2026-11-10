locals {
  app_subnet_ids = [
    var.subnet_ids["sn-app-a"],
    var.subnet_ids["sn-app-b"],
  ]
  sg_lambda_id = var.sg_lambda_id

  db_endpoint   = var.db_endpoint # "<host>:<port>"
  db_host       = split(":", local.db_endpoint)[0]
  db_port       = split(":", local.db_endpoint)[1]
  db_name       = var.db_name
  db_secret_arn = var.db_secret_arn

  # fn-reminder-dispatcher only — see modules/data's note on why this one
  # read path is safe against replication lag when nothing else is.
  db_replica_endpoint = var.db_replica_endpoint # "<host>:<port>"
  db_replica_host     = split(":", local.db_replica_endpoint)[0]
  db_replica_port     = split(":", local.db_replica_endpoint)[1]

  user_pool_arn = var.user_pool_arn
}

# ==========================================================================
# SQS queue — §10.1
# ==========================================================================
# Replaces the old SNS topic + per-user filter-policy subscription model.
# Producers (the API, and fn-reminder-dispatcher) resolve the recipient's
# email themselves and enqueue {to, subject, body} directly — no
# subscription/confirmation step, no per-user SNS bookkeeping.

resource "aws_sqs_queue" "notifications_dlq" {
  name                      = "${var.sqs_queue_name}-dlq"
  message_retention_seconds = 1209600 # 14 days — long enough to notice and inspect failures

  tags = {
    Name    = "${var.sqs_queue_name}-dlq"
    Project = "hisaab"
  }
}

resource "aws_sqs_queue" "notifications" {
  name = var.sqs_queue_name

  # >=6x the email-sender Lambda's 30s timeout, per AWS's own guidance for
  # SQS-Lambda visibility timeouts — avoids a message becoming visible
  # again (and double-sent) while a slow invocation is still processing it.
  visibility_timeout_seconds = 180

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notifications_dlq.arn
    maxReceiveCount     = 5
  })

  tags = {
    Name    = var.sqs_queue_name
    Project = "hisaab"
  }
}
