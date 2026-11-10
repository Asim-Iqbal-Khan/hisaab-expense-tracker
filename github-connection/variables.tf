variable "aws_region" {
  description = "AWS region for the connection resource"
  type        = string
  default     = "us-west-2"
}

variable "connection_name" {
  description = "Name of the CodeStar (CodeConnections) GitHub connection"
  type        = string
  default     = "hisaab-github"
}
