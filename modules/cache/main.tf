locals {
  data_subnet_ids = [
    var.subnet_ids["sn-data-a"],
    var.subnet_ids["sn-data-b"],
  ]
}

# ==========================================================================
# ElastiCache subnet group
# ==========================================================================
# Reuses sn-data-a/sn-data-b — the same private, no-internet-route subnets
# RDS already lives in. A cache needs exactly the same isolation a database
# does.

resource "aws_elasticache_subnet_group" "hisaab" {
  name        = "hisaab-cache-subnet-group"
  description = "sn-data-a, sn-data-b"
  subnet_ids  = local.data_subnet_ids
}

# ==========================================================================
# Redis — balance/expense query cache
# ==========================================================================
# Single node, no automatic failover, single-AZ — see var.node_type's
# description for why: this is a performance cache, not a hard dependency,
# and the app is expected to fall through to the database if it's ever
# unavailable rather than needing HA here.
#
# Encrypted at rest and in transit (matching this project's
# encryption-everywhere posture elsewhere: RDS storage, S3 buckets, Secrets
# Manager) but no auth_token — access control is the security group alone
# (sg-cache, only reachable from sg-app), the same trust model the app
# already has toward RDS from inside the VPC. Skips managing a second
# credential for a resource that's genuinely unreachable from anywhere but
# sg-app in the first place.

resource "aws_elasticache_replication_group" "hisaab" {
  replication_group_id = "hisaab-cache"
  description          = "Balance/expense query cache"

  engine         = "redis"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  subnet_group_name  = aws_elasticache_subnet_group.hisaab.name
  security_group_ids = [var.sg_cache_id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  tags = {
    Name    = "hisaab-cache"
    Project = "hisaab"
  }
}
