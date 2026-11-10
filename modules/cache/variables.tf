variable "aws_region" {
  description = "AWS region for all Hisaab infrastructure"
  type        = string
  default     = "us-west-2"
}

variable "subnet_ids" {
  description = "Map of subnet name to subnet ID, from modules/network"
  type        = map(string)
}

variable "sg_cache_id" {
  description = "sg-cache security group ID, from modules/security"
  type        = string
}

variable "node_type" {
  description = "ElastiCache node instance class. Single node, no automatic failover — this is a performance cache, not a hard dependency; the app falls through to the database if it's ever unavailable, so paying for HA here isn't worth it (same reasoning as the read replica's single-AZ choice)."
  type        = string
  default     = "cache.t4g.micro"
}

variable "engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}
