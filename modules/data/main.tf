# TODO: hisaab-schema.sql (including `CREATE EXTENSION citext;`) is not
# applied here. Per spec §7.3/§16 D16, DDL runs through a separate migration
# step (Flyway or golang-migrate, still open per §17.1) — never a
# null_resource + psql provisioner, which would break Terraform's state
# model. This module only provisions the empty database.

locals {
  data_subnet_ids = [
    var.subnet_ids["sn-data-a"],
    var.subnet_ids["sn-data-b"],
  ]
  sg_data_id = var.sg_data_id
}

# ==========================================================================
# DB subnet group — §7
# ==========================================================================

resource "aws_db_subnet_group" "hisaab" {
  name        = "hisaab-db-subnet-group"
  description = "sn-data-a, sn-data-b"
  subnet_ids  = local.data_subnet_ids

  tags = {
    Name    = "hisaab-db-subnet-group"
    Project = "hisaab"
  }
}

# ==========================================================================
# Enhanced monitoring role
# ==========================================================================
# Required companion resource for monitoring_interval > 0 — RDS assumes
# this role to publish OS-level metrics to CloudWatch Logs. Not listed by
# name in spec §11, but there's no way to get the enhanced monitoring §7
# asks for without it.

resource "aws_iam_role" "rds_monitoring" {
  name = "role-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "monitoring.rds.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = {
    Name    = "role-rds-monitoring"
    Project = "hisaab"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ==========================================================================
# RDS Postgres, Multi-AZ — §7
# ==========================================================================
# The Multi-AZ standby below is a synchronous replica for failover only —
# it serves zero reads and there is no reader endpoint for it (§7.1,
# decision D11). That's a completely different thing from the real read
# replica further down (hisaab_reminder_replica): a separate,
# asynchronously-replicated instance with its own genuine endpoint, added
# deliberately for exactly one read path that can tolerate replication
# lag. Don't confuse the two when reading this file.

resource "aws_db_instance" "hisaab" {
  identifier     = "hisaab-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true # AWS-managed KMS key (default aws/rds); kms_key_id intentionally omitted

  multi_az = true

  db_name  = var.db_name
  username = var.db_master_username

  # Self-managed password, not manage_master_user_password — AWS flatly
  # refuses to create a read replica from a Postgres instance using the
  # RDS-managed password feature ("InvalidParameterValue: Creating read
  # replicas for source instance with engine postgres where
  # ManageMasterUserPassword is enabled is not supported"), confirmed by a
  # real failed apply. This trades away RDS's automatic 30-day rotation —
  # a deliberate, known regression from the spec's original §7.2 design,
  # accepted here specifically so the read replica below can exist.
  #
  # password_wo (write-only), not password — the value itself is never
  # persisted into this resource's own state. It still ends up in
  # aws_secretsmanager_secret_version.hisaab_db's state below, though:
  # something has to actually hold the live value for the app to read at
  # runtime, and that's Secrets Manager, same as before. Bump
  # var.db_master_password_version to push a changed password later.
  password_wo         = var.db_master_password
  password_wo_version = var.db_master_password_version

  db_subnet_group_name   = aws_db_subnet_group.hisaab.name
  vpc_security_group_ids = [local.sg_data_id]
  publicly_accessible    = false

  backup_retention_period = 7
  backup_window           = "09:00-10:00"
  maintenance_window      = "tue:10:00-tue:11:00"

  deletion_protection       = var.rds_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "hisaab-db-final"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  tags = {
    Name    = "rds-hisaab"
    Project = "hisaab"
  }
}

# ==========================================================================
# Read replica — scoped to fn-reminder-dispatcher only
# ==========================================================================
# Exactly one read path uses this: the weekly reminder job's balance scan.
# That job is a scheduled batch run, not a live user request, and scans
# across every indebted user at once — the one read in this app where
# async replication lag genuinely doesn't matter, unlike balances/
# expenses/settlements shown right back to a user immediately after their
# own write, which all stay on the primary above. See
# modules/messaging/src/reminder_dispatcher for where this is actually
# used.
#
# Single-AZ on purpose: this only serves one low-stakes weekly batch job,
# not interactive traffic, so paying to double its own availability isn't
# worth it the way it is for the primary.
#
# Inherits the primary's engine, storage, database, and master credentials
# automatically (replicate_source_db) — same Secrets Manager secret works
# for both, no separate credential to manage or grant.
#
# storage_encrypted is explicitly declared (true, matching the primary)
# even though it's also true in AWS's reality without saying so —
# confirmed the hard way: leaving it unset here caused every subsequent
# plan to see "true" live vs. "unset" in this config as drift, and want
# to fix it by destroying and recreating the entire replica. Encryption
# can't be toggled in-place, hence the replacement — an inherited-but-
# undeclared attribute silently threatening to blow away a resource that
# was already exactly right.

resource "aws_db_instance" "hisaab_reminder_replica" {
  identifier            = "hisaab-db-reminder-replica"
  replicate_source_db   = aws_db_instance.hisaab.arn
  instance_class        = "db.t4g.micro"
  storage_encrypted     = true
  max_allocated_storage = 100 # matches the primary — same "declare inherited values explicitly" reasoning as storage_encrypted above

  db_subnet_group_name   = aws_db_subnet_group.hisaab.name
  vpc_security_group_ids = [local.sg_data_id]
  publicly_accessible    = false

  skip_final_snapshot = true

  tags = {
    Name    = "hisaab-db-reminder-replica"
    Project = "hisaab"
  }
}

# ==========================================================================
# Self-managed master password secret — §7.2 (regressed on purpose)
# ==========================================================================
# Replaces the RDS-managed secret this project originally relied on for
# automatic 30-day rotation (see the note on aws_db_instance.hisaab above
# for why that had to go — read replicas and ManageMasterUserPassword are
# mutually exclusive on RDS Postgres). Same JSON shape ({"username":...,
# "password":...}) as the RDS-managed secret it replaces, so every place
# that already reads this (backend, both VPC Lambdas, the EC2 boot/deploy
# scripts) needed zero code changes — only local.db_secret_arn below
# needed to point somewhere new.
#
# No rotation configured here — RDS-managed rotation used an AWS-internal
# mechanism with no customer Lambda involved at all; replacing that with
# equivalent automatic rotation would mean standing up a real rotation
# Lambda, which is a deliberately unrequested amount of extra complexity
# for a personal project's database. Rotating this password later means
# manually bumping var.db_master_password_version with a new value.

resource "aws_secretsmanager_secret" "hisaab_db" {
  name = "hisaab-db-master-password"

  tags = {
    Name    = "hisaab-db-master-password"
    Project = "hisaab"
  }
}

resource "aws_secretsmanager_secret_version" "hisaab_db" {
  secret_id = aws_secretsmanager_secret.hisaab_db.id
  secret_string = jsonencode({
    username = var.db_master_username
    password = var.db_master_password
  })
}

# ==========================================================================
# Grant DB secret read to the roles that need it
# ==========================================================================
# Deferred from modules/security (phase 2) because the secret's ARN didn't
# exist yet. Attached here, now that it does.

locals {
  db_secret_arn = aws_secretsmanager_secret.hisaab_db.arn
}

resource "aws_iam_role_policy" "ec2_hisaab_db_secret" {
  name = "role-ec2-hisaab-db-secret-read"
  role = var.role_ec2_hisaab_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DbSecretRead"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = local.db_secret_arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "lambda_postconfirm_db_secret" {
  name = "role-lambda-postconfirm-db-secret-read"
  role = var.role_lambda_postconfirm_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DbSecretRead"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = local.db_secret_arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "lambda_reminder_db_secret" {
  name = "role-lambda-reminder-db-secret-read"
  role = var.role_lambda_reminder_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DbSecretRead"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = local.db_secret_arn
      },
    ]
  })
}
