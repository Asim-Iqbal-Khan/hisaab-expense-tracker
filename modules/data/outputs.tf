output "db_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.hisaab.id
}

output "db_instance_arn" {
  description = "RDS instance ARN"
  value       = aws_db_instance.hisaab.arn
}

output "db_endpoint" {
  description = "Connection endpoint (host:port). Same endpoint before and after failover — RDS repoints its DNS, the app never sees a different address."
  value       = aws_db_instance.hisaab.endpoint
}

output "db_name" {
  description = "Initial database name"
  value       = aws_db_instance.hisaab.db_name
}

output "db_replica_endpoint" {
  description = "Connection endpoint (host:port) of the fn-reminder-dispatcher-only read replica"
  value       = aws_db_instance.hisaab_reminder_replica.endpoint
}

output "db_secret_arn" {
  description = "ARN of the self-managed master password secret in Secrets Manager (see main.tf's note on why this isn't RDS-managed anymore)"
  value       = aws_secretsmanager_secret.hisaab_db.arn
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group"
  value       = aws_db_subnet_group.hisaab.name
}
