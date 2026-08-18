terraform {
  backend "s3" {
    bucket       = "nexops-terraform-state-234951664471"
    key          = "nexops/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}