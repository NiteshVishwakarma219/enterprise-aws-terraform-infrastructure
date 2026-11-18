variable "name_prefix" {
  description = "Prefix used for database resource names"
  type        = string
}

variable "db_subnet_ids" {
  description = "Private database subnet IDs"
  type        = list(string)
}

variable "db_security_group_id" {
  description = "Security group ID allowed to reach the database"
  type        = string
}

variable "db_name" {
  description = "Initial database name"
  type        = string
}

variable "db_username" {
  description = "Master username for the database"
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16.14"
}

variable "db_allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Whether to deploy a Multi-AZ standby replica"
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on destroy (set false for real production use)"
  type        = bool
  default     = true
}

variable "admin_demo_password" {
  description = "Default password for the admin demo user"
  type        = string
  sensitive   = true
  default     = "Admin@NexOps2026"
}

variable "hr_demo_password" {
  description = "Default password for the HR demo user"
  type        = string
  sensitive   = true
  default     = "HrPortal@2026"
}

variable "manager_demo_password" {
  description = "Default password for the manager demo user"
  type        = string
  sensitive   = true
  default     = "Manager@2026"
}

variable "employee_demo_password" {
  description = "Default password for the employee demo user"
  type        = string
  sensitive   = true
  default     = "Employee@2026"
}
