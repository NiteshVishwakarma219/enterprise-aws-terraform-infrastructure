# ============================================================
# RANDOM PASSWORD FOR THE DATABASE MASTER USER
# ============================================================

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
  special = false
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

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.db_security_group_id]

  multi_az                   = var.multi_az
  publicly_accessible        = false
  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  skip_final_snapshot        = var.skip_final_snapshot
  final_snapshot_identifier  = var.skip_final_snapshot ? null : "${var.name_prefix}-db-final-snapshot"
  deletion_protection        = false

  tags = {
    Name = "${var.name_prefix}-db"
  }
}

# ============================================================
# SECRETS MANAGER - STORES DB & DEMO ACCOUNT CREDENTIALS
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
    username      = var.db_username
    password      = random_password.db.result
    database      = var.db_name
    host          = aws_db_instance.main.address
    port          = aws_db_instance.main.port
    jwt_secret    = random_password.jwt.result
    admin_demo    = var.admin_demo_password
    hr_demo       = var.hr_demo_password
    manager_demo  = var.manager_demo_password
    employee_demo = var.employee_demo_password
  })
}
