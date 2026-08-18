# ============================================================
# RANDOM PASSWORD FOR THE DATABASE MASTER USER
# ============================================================
#
# override_special is intentionally limited to characters that are
# always safe unencoded inside a URI (RFC 3986 "unreserved" set).
# The default random_password character set includes things like
# : { } ( ) < > which break naive postgresql://user:pass@host URLs
# built by string concatenation in user_data.sh.tpl.

resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "-_.~"
}

# ============================================================
# RANDOM SECRET FOR SIGNING JWTs
# ============================================================

resource "random_password" "jwt" {
  length  = 48
  special = false   # goes straight into a shell -e JWT_SECRET="..." value; keep it simple/safe
}

# ============================================================
# DB SUBNET GROUP
# ============================================================

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = var.db_subnet_ids

  tags = {
    Name = "${var.name_prefix}-db-subnet-group"
  }
}

# ============================================================
# RDS POSTGRESQL INSTANCE
# ============================================================

resource "aws_db_instance" "main" {
  identifier     = "${var.name_prefix}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
  port     = 5432

  db_subnet_group_name  = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.db_security_group_id]

  multi_az                = var.multi_az
  publicly_accessible     = false
  backup_retention_period = 1
  auto_minor_version_upgrade = true
  skip_final_snapshot     = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-db-final-snapshot"
  deletion_protection     = false

  tags = {
    Name = "${var.name_prefix}-db"
  }
}

# ============================================================
# SECRETS MANAGER - stores connection details for the app
# (keys match what modules/compute's user_data script reads:
#  username, password, database, host, port)
# ============================================================

resource "aws_secretsmanager_secret" "db" {
  name = "${var.name_prefix}-db-credentials"

  tags = {
    Name = "${var.name_prefix}-db-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    database = var.db_name
    host     = aws_db_instance.main.address
    port         = aws_db_instance.main.port
    jwt_secret   = random_password.jwt.result
    admin_demo   = random_password.admin_demo.result
    hr_demo      = random_password.hr_demo.result
    manager_demo = random_password.manager_demo.result
    employee_demo = random_password.employee_demo.result
  })
}
