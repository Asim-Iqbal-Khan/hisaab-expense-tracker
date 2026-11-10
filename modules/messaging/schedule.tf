# ==========================================================================
# EventBridge Scheduler → fn-reminder-dispatcher — §10.3
# ==========================================================================
# role-eventbridge-scheduler isn't in spec §11's role table — like
# role-rds-monitoring and role-vpc-flow-logs before it, it's a required
# companion resource: the Scheduler service needs a role to assume in order
# to invoke the Lambda, there's no way around creating one.

resource "aws_iam_role" "eventbridge_scheduler" {
  name = "role-eventbridge-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "scheduler.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = {
    Name    = "role-eventbridge-scheduler"
    Project = "hisaab"
  }
}

resource "aws_iam_role_policy" "eventbridge_scheduler_invoke" {
  name = "invoke-reminder-dispatcher"
  role = aws_iam_role.eventbridge_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeReminderDispatcher"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.reminder_dispatcher.arn
      },
    ]
  })
}

resource "aws_scheduler_schedule" "weekly_reminder" {
  name        = "sched-weekly-reminder"
  description = "Weekly settlement reminder dispatch (§10.3)"

  schedule_expression = var.reminder_schedule_expression

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.reminder_dispatcher.arn
    role_arn = aws_iam_role.eventbridge_scheduler.arn
  }
}
