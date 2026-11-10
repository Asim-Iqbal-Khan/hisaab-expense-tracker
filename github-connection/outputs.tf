output "connection_arn" {
  description = "ARN of the GitHub CodeStar connection, consumed by envs/prod's pipeline module"
  value       = aws_codestarconnections_connection.github.arn
}

output "connection_status" {
  description = "PENDING until authorized once in the console; AVAILABLE after"
  value       = aws_codestarconnections_connection.github.connection_status
}
