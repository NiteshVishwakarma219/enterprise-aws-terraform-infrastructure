# ============================================================
# VPC
# ============================================================

module "vpc" {
  source = "../../modules/vpc"

  name_prefix         = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  azs                 = var.azs
  public_subnet_cidrs = var.public_subnet_cidrs
  app_subnet_cidrs    = var.app_subnet_cidrs
  db_subnet_cidrs     = var.db_subnet_cidrs
}

# ============================================================
# SECURITY GROUPS
# ============================================================

module "security" {
  source = "../../modules/security"

  name_prefix = local.name_prefix
  vpc_id      = module.vpc.vpc_id
}

# ============================================================
# S3 UPLOADS BUCKET
# ============================================================

module "storage" {
  source = "../../modules/storage"

  name_prefix = local.name_prefix
}

# ============================================================
# RDS DATABASE + SECRETS MANAGER
# ============================================================

module "database" {
  source = "../../modules/database"

  name_prefix            = local.name_prefix
  db_subnet_ids          = module.vpc.db_subnet_ids
  db_security_group_id   = module.security.db_security_group_id
  db_name                = var.db_name
  db_username            = var.db_username
  db_instance_class      = var.db_instance_class
  multi_az               = var.multi_az
  admin_demo_password    = var.admin_demo_password
  hr_demo_password       = var.hr_demo_password
  manager_demo_password  = var.manager_demo_password
  employee_demo_password = var.employee_demo_password
}

# ==================================e==========================
# IAM (Lambda execution role)
# ============================================================

module "iam" {
  source = "../../modules/iam"

  name_prefix        = local.name_prefix
  uploads_bucket_arn = module.storage.bucket_arn
}

# ============================================================
# COMPUTE (ALB + Auto Scaling Group + Launch Template)
# ============================================================

module "compute" {
  source = "../../modules/compute"

  name_prefix           = local.name_prefix
  vpc_id                = module.vpc.vpc_id
  app_subnet_ids        = module.vpc.app_subnet_ids
  public_subnet_ids     = module.vpc.public_subnet_ids
  app_security_group_id = module.security.app_security_group_id
  alb_security_group_id = module.security.alb_security_group_id

  backend_image        = var.backend_image
  frontend_image       = var.frontend_image
  database_secret_name = module.database.database_secret_name
  database_secret_arn  = module.database.database_secret_arn
  uploads_bucket_arn   = module.storage.bucket_arn
  aws_region           = var.aws_region

  instance_type        = var.instance_type
  asg_min_size         = var.asg_min_size
  asg_max_size         = var.asg_max_size
  asg_desired_capacity = var.asg_desired_capacity
}

# ============================================================
# LAMBDA (scheduled housekeeping)
# ============================================================

module "lambda" {
  source = "../../modules/lambda"

  name_prefix         = local.name_prefix
  lambda_role_arn     = module.iam.lambda_role_arn
  uploads_bucket_name = module.storage.bucket_name
}

# ============================================================
# MONITORING (SNS + CloudWatch alarms)
# ============================================================

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix            = local.name_prefix
  alert_email            = var.alert_email
  autoscaling_group_name = module.compute.autoscaling_group_name
  alb_full_name          = module.compute.alb_full_name
  target_group_full_name = module.compute.target_group_full_name
  db_instance_id         = module.database.db_instance_id
}
