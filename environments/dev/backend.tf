terraform {
  backend "s3" {
    bucket       = "nexops-terraform-state-920235988251"
    key          = "nexops/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}