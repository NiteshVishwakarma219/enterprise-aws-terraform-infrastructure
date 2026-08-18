resource "random_password" "admin_demo" {
  length  = 20
  special = true
}

resource "random_password" "hr_demo" {
  length  = 20
  special = true
}

resource "random_password" "manager_demo" {
  length  = 20
  special = true
}

resource "random_password" "employee_demo" {
  length  = 20
  special = true
}