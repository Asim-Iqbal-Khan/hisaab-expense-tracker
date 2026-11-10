output "sqs_queue_url" {
  description = "URL of the hisaab-notifications SQS queue"
  value       = aws_sqs_queue.notifications.url
}

output "sqs_queue_arn" {
  description = "ARN of the hisaab-notifications SQS queue"
  value       = aws_sqs_queue.notifications.arn
}

output "post_confirmation_function_arn" {
  description = "ARN of fn-post-confirmation"
  value       = aws_lambda_function.post_confirmation.arn
}

output "reminder_dispatcher_function_arn" {
  description = "ARN of fn-reminder-dispatcher"
  value       = aws_lambda_function.reminder_dispatcher.arn
}

output "reminder_schedule_arn" {
  description = "ARN of the weekly reminder EventBridge schedule"
  value       = aws_scheduler_schedule.weekly_reminder.arn
}
